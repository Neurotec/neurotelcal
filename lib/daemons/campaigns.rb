#!/usr/bin/env ruby
require 'daemons'
# You might want to change this
ENV["RAILS_ENV"] ||= "production"

require File.dirname(__FILE__) + "/../../config/environment"
#Rails.application.require_environment!


$running = true
Signal.trap("TERM") do 
  $running = false
end

running_campaings = {}
while($running) do
  Rails.logger.auto_flushing = true
  Rails.logger.info "Procesing campaigns"


  Campaign.all.each do |campaign|
    next running_campaings.key?(campaign.id)
    Rails.logger.info "Testing campaign #{campaign.name}"

    running_campaings[campaign.id] = Thread.new {
      Rails.logger.info("Processing campaign #{campaign.name}")
      CampaignService.new(campaign.id).process(true)
      Rails.logger.info("Stopped campaign #{campaign.name}")
      ActiveRecord::Base.connection.close
    }

  end
  
  sleep 1
  running_campaings.each do |campaign_id, thread|
    if thread.stop?
      running_campaings.delete(campaign.id)
    end
  end

end

running_campaings.each do |campaign_id, thread|
  thread.join
end
