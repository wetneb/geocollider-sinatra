#!/usr/bin/env ruby

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'sinatra/base'
require 'tempfile'
require 'haml'
require 'geocollider'

# JS/CSS asset management
require 'sprockets'
require 'uglifier'
require 'sass'
require 'coffee-script'
require 'execjs'

# Airbrake
airbrake_config = {}
if File.exist?('airbrake.yml') || (ENV['AIRBRAKE_PROJECT_ID'] && ENV['AIRBRAKE_PROJECT_KEY'])
  $stderr.puts 'Configuring Airbrake...'

  require 'airbrake'
  require 'yaml'

  if File.exist?('airbrake.yml')
    airbrake_config = YAML.load_file('airbrake.yml')
  else
    airbrake_config[:project_id] = ENV['AIRBRAKE_PROJECT_ID']
    airbrake_config[:project_key] = ENV['AIRBRAKE_PROJECT_KEY']
  end

  Airbrake.configure do |c|
    c.project_id = airbrake_config[:project_id]
    c.project_key = airbrake_config[:project_key]

    # Display debug output.
    c.logger.level = Logger::DEBUG
  end
end

class GeocolliderSinatra < Sinatra::Base
  if airbrake_config != {}
    $stderr.puts 'Using Airbrake middleware...'
    use Airbrake::Rack::Middleware
  end

  NORMALIZATION_DEFAULTS = %w{whitespace case accents punctuation nfc}

  def initialize
    super()
    @pleiades = Geocollider::PleiadesParser.new()
    @pleiades_parses = {}
    @tempfiles = []
    parse_pleiades(NORMALIZATION_DEFAULTS)
  end

  helpers do
    def parse_pleiades(normalizations)
      normalizations.sort!
      unless @pleiades_parses.has_key?(normalizations)
        $stderr.puts "No existing parse for normalizations: #{normalizations.join(' ')}\nParsing..."
        string_normalizer_lambda = Geocollider::StringNormalizer.normalizer_lambda(normalizations)
        @pleiades_parses[normalizations] = @pleiades.parse(Geocollider::PleiadesParser::FILENAMES, string_normalizer_lambda)
        $stderr.puts "Parsing done for normalizations: #{normalizations.join(' ')}"
      end
      return @pleiades_parses[normalizations]
    end
  end

  # initialize new sprockets environment
  set :environment, Sprockets::Environment.new

  # append assets paths
  environment.append_path "assets/stylesheets"
  environment.append_path "assets/javascripts"

  # compress assets
  environment.js_compressor  = :uglify
  environment.css_compressor = :scss

  environment.context_class.class_eval do
    def asset_path(path, options = {})
      "/assets/#{path}"
    end
  end

  # get assets
  get "/assets/*" do
    env["PATH_INFO"].sub!("/assets", "")
    settings.environment.call(env)
  end

  get '/' do
    haml :upload
  end

  get '/upload' do
    haml :upload
  end

  post '/upload' do
    $stderr.puts params['csvfile'][:filename]
    upload_basename = File.basename(params['csvfile'][:filename], File.extname(params['csvfile'][:filename]))
    $stderr.puts upload_basename
    tempfile_file = Tempfile.new([upload_basename + '_','.csv'])
    tempfile_file.close
    @tempfiles << tempfile_file # prevent GC/deletion until we close
    @uploaded_filename = tempfile_file.path
    $stderr.puts @uploaded_filename
    File.open(@uploaded_filename, "wb") do |f|
      f.write(params['csvfile'][:tempfile].read)
    end

    @csv_preview = File.open(@uploaded_filename,"r:bom|utf-8").read.force_encoding('UTF-8').encode('UTF-8', :invalid => :replace, :universal_newline => true).lines().first(3).join("\n").squeeze("\n")
    haml :post_upload
  end

  post '/process' do
    $stderr.puts params.inspect

    csv_options = {
      :separator => params['separator'] == 'tab' ? "\t" : ',',
      :quote_char => params['quote_char'].empty? ? "\u{FFFF}" : params['quote_char'],
      :names => params['names'].split(','),
      :lat => params['lat'],
      :lon => params['lon'],
      :id => params['id'],
      :headers => (params['headers'] == 'true'),
      :string_normalizer => Geocollider::StringNormalizer.normalizer_lambda(params['normalize'])
    }
    $stderr.puts csv_options.inspect
    csv_parser = Geocollider::CSVParser.new(csv_options)

    pleiades_names, pleiades_places = parse_pleiades(params['normalize'])
    Tempfile.open(['processed_','.csv']) do |output_tempfile|
      CSV.open(output_tempfile, 'wb') do |csv|
        csv_comparison = csv_parser.comparison_lambda(pleiades_names, pleiades_places, csv)
        if(params['algorithm'] == 'name')
          csv_comparison = csv_parser.string_comparison_lambda(pleiades_names, pleiades_places, csv)
        end
        csv_parser.parse([params['csvfile']], csv_comparison)
      end
      response.headers['Content-Disposition'] = "attachment; filename=geocollider_results-#{Time.now.strftime("%Y-%m-%d-%H-%M-%S")}.csv"
      File.read(output_tempfile.path)
    end
  end
end
