#!/usr/bin/env ruby
# encoding: utf-8

require 'google/apis/gmail_v1'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'open-uri'
require 'addressable/uri'
require 'nokogiri'
require 'typhoeus'
require 'csv'
require 'securerandom'

# Assumptions: linux-based OS, ruby 2+
# See https://developers.google.com/gmail/api/quickstart/ruby & do Step 1
# Create a Google Scholar email alert using whatever search terms are relevant, send it to a gmail account
# Create a filter in gmail to send messages to a "Scholar" label
# $ gem install google-api-client fileutils open-uri addressable nokogiri typhoeus securerandom
# First time execution of this script will prompt to visit a URL, then copy secret code into command line
# Subsequent executions will used cached secret from above

OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'
APPLICATION_NAME = 'Gmail API Ruby'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH = File.join(".credentials", "gmail-ruby.yaml")
SCOPE = Google::Apis::GmailV1::AUTH_SCOPE
GMAIL_LABEL = 'Scholar'
RESULTS_PATH = 'results'
REFERENCE_STYLE_URL = 'https://citation.crosscite.org/format?style=entomologia-experimentalis-et-applicata&lang=en-US&doi='
SCI_HUB_URL = 'http://sci-hub.bz/'
HYDRA = Typhoeus::Hydra.hydra

##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization. If authorization is required,
# the user's default browser will be launched to approve the request.
#
# @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
def authorize
  FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))
  client_id = Google::Auth::ClientId.from_file(CLIENT_SECRETS_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: CREDENTIALS_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)
  if credentials.nil?
    url = authorizer.get_authorization_url(base_url: OOB_URI)
    puts "Open the following URL in the browser and enter the " +
         "resulting code after authorization"
    puts url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(user_id: user_id, code: code, base_url: OOB_URI)
  end
  credentials
end

def extract_scholar_urls(body)
  doc = Nokogiri::HTML(body)
  doc.xpath("//*/a").collect{|l| l['href']}
     .delete_if{|u| !u.include?("scholar_url")}
end

def extract_doi_from_url(url)
  doi_pattern = /(10[.][0-9]{4,}(?:[.][0-9]+)*\/(?:(?![%"#? ])\S)+)/i
  strip_out = %r{
    \/full|
    \/abstract|
    \.pdf|
    \&type=printable
  }x
  doi = url.match(doi_pattern).captures.first rescue nil
  doi.gsub(strip_out, '') if doi
end

def extract_publisher_url(url)
  uri = Addressable::URI.parse(url)
  uri.query_values["url"]
end

def generate_reference(doi)
  request = Typhoeus.get(REFERENCE_STYLE_URL + doi, timeout: 10)
  request.response_body
end

def generate_request(uuid, url)
  downloaded_file = File.open File.join(RESULTS_PATH, "#{uuid}.pdf"), 'wb'
  request = Typhoeus::Request.new(url)
  request.on_body do |chunk|
    downloaded_file.write(chunk)
  end
  request.on_complete do |response|
    downloaded_file.close
  end
  request
end

def download_request(item)
  if File.extname(item[:url]) == ".pdf"
    generate_request(item[:uuid], item[:url])
  elsif item[:doi]
    request = Typhoeus::Request.new(SCI_HUB_URL + item[:url])
    request.on_complete do |response|
      doc = Nokogiri::HTML(response.body)
      url = doc.xpath("//*/iframe[@id='pdf']").first.attributes["src"].value rescue nil
        HYDRA.queue generate_request(item[:uuid], "http:#{url}") if url
    end
    request
  end
end

citations = []

# Initialize the API
service = Google::Apis::GmailV1::GmailService.new
service.client_options.application_name = APPLICATION_NAME
service.authorization = authorize

labels = service.list_user_labels("me").labels
scholar_id = labels.select{|label| label.name == GMAIL_LABEL}.first.id
message_ids = service.list_user_messages("me", { label_ids: ["#{scholar_id}"] })
                     .messages.collect(&:id)
message_ids.each do |id|
  message = service.get_user_message("me", id)
  payload = message.payload
  body = payload.body.data
  if body.nil? && payload.parts.any?
    body = payload.parts.map{|part| part.body.data}.join
  end
  urls = extract_scholar_urls(body)
  urls.each do |url|
    uuid = SecureRandom.uuid
    url = extract_publisher_url(url)
    puts url
    doi = extract_doi_from_url(url)
    reference = generate_reference(doi) if doi
    citations << { uuid: uuid, doi: doi, url: url, reference: reference }
  end
  # DELETE the email message
  #service.delete_user_message("me", id)
end

puts "Saving csv..."

CSV.open(File.join(RESULTS_PATH, 'output.csv'), 'w') do |csv|
  csv << ["UUID", "URL", "DOI", "Reference"]
  citations.each do |item|
    csv << [item[:uuid], item[:url], item[:doi], item[:reference]]
  end
end

puts "Downloading pdfs..."

citations.shuffle.each do |item|
  request = download_request(item)
  HYDRA.queue request if !request.nil?
end

HYDRA.run

