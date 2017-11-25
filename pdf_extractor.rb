#!/usr/bin/env ruby
# encoding: utf-8

require 'pdf-reader'

RESULTS_PATH = 'results'

COLLECTION_CODE = %r{
  \bCAN[ALM]?\s[0-9]{1,}\b|
  \bCMN[ABCEFILMNPVY]{1,3}?\s[0-9]{1,}-?[0-9]{1,}?\b|
  \bNMC\s[0-9]{1,}\b
}x

Dir.foreach(RESULTS_PATH) do |item|
  next if item == '.' or item == '..' or File.extname(item) != ".pdf"
  reader = PDF::Reader.new(File.join(RESULTS_PATH,item)) rescue nil
  if reader
    codes = []
    reader.pages.each do |page|
      matches = page.text.scan(COLLECTION_CODE)
      if !matches.empty?
        codes << matches
      end
    end
    codes = { uuid: File.basename(item, ".pdf"), catalog_items: codes.flatten.uniq }
    puts codes
  end
end