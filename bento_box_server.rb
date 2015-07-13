#!/usr/bin/env ruby
# -*- encoding: utf-8 -*-

Signal.trap("INT") { exit 1 }

$stdout.sync = true
$stderr.sync = true

require "json"
require "rubygems/version"
require "webrick"

module Bento
  class BoxDatabase
    def initialize(root, prefix)
      @root = root
      @prefix = prefix
    end

    def boxes
      if @db.nil? || last_metadata_mtime > last_db_load_time
        @db = populate_db
      else
        @db
      end
    end

    def [](*args)
      boxes[*args]
    end

    private

    attr_reader :root, :prefix

    def last_metadata_mtime
      metadatas.map { |metadata| File.mtime(metadata) }.max || Time.now
    end

    def metadatas
      Dir.glob(File.join(root, "*.metadata.json")).sort
    end

    def populate_db
      $stdout.puts "==> Loading or refreshing box metadata db"
      raw = metadatas.
        map { |file| JSON.load(IO.read(file)) }.
        map { |h|
          {
            "name" => [prefix, h["name"]].join("/"),
            "description" => h.fetch("description", "N/A"),
            "versions" => [
              {
                "version" => h["version"],
                "providers" => h["providers"]
              }
            ]
          }
        }.group_by { |h| h["name"] }

      raw.each do |name, data|
        sorted = data.sort do |a, b|
          a_version = Gem::Version.new(a["versions"].first["version"])
          b_version = Gem::Version.new(b["versions"].first["version"])

          a_version <=> b_version
        end

        raw[name] = {
          "name" => sorted.last["name"],
          "description" => sorted.last["description"],
          "versions" => sorted.map { |h| h["versions"].first }
        }
      end

      @last_db_load_time = Time.now

      raw
    end

    def last_db_load_time
      @last_db_load_time
    end
  end

  class BoxServer
    def initialize(root, port, prefix)
      @server = WEBrick::HTTPServer.new(Port: port, DocumentRoot: root)
      @server.mount("/boxes", BoxesServlet, BoxDatabase.new(root, prefix))
      trap("INT") { @server.shutdown }
      trap("TERM") { @server.shutdown }
    end

    def start
      @server.start
    end
  end

  class BoxesServlet < WEBrick::HTTPServlet::AbstractServlet
    attr_reader :db

    def initialize(server, db)
      super(server)
      @db = db
    end

    def do_GET(request, response)
      response.content_type = "application/json"
      box = request.path_info.sub(%r{^/}, "")

      if box.empty?
        list_boxes(request, response)
      elsif data = db[box]
        get_box_metadata(request, response, data)
      else
        return_not_found(request, response, box)
      end
    end

    private

    def get_box_metadata(request, response, data)
      web_root = request.request_uri.dup.tap { |uri| uri.path = "/" }.to_s
      update_urls!(data, web_root)

      response.status = 200
      response.body = json(data)
    end

    def json(data)
      JSON.pretty_generate(data).concat("\n")
    end

    def list_boxes(request, response)
      boxes = db.boxes.keys.map do |box|
        [
          box,
          {
            "url" => File.join(request.request_uri.to_s, box),
            "versions" => db[box]["versions"].map { |h| h["version"] }
          }
        ]
      end

      response.status = 200
      response.body = json(Hash[boxes])
    end

    def return_not_found(request, response, box)
      response.status = 404
      response.body = json(error: "No box #{box} found.")
    end

    def update_urls!(data, web_root)
      data["versions"].each do |version|
        version["providers"].each do |provider|
          provider["url"] = "#{web_root}#{provider["file"]}"
        end
      end
    end
  end
end

if $0 == __FILE__
  root = ARGV[0]
  abort "usage: #{$0} <ROOT_PATH>" unless root
  abort "ROOT_PATH: #{root} must exist!" unless File.directory?(root)
  prefix = ENV.fetch("PREFIX", "bento")
  port = ENV.fetch("PORT", 8000).to_i

  Bento::BoxServer.new(root, port, prefix).start
end
