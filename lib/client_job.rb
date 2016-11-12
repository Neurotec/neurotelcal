# Copyright (C) 2012 Bit4Bit::ClientJob.new(file, session[:user_id], session[:campaign_id], session[:group_id]), :queue => 'clients_import') <bit4bit@riseup.net>
#
#
# This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.



class ClientJob < Struct.new(:file,  :user_id, :campaign_id, :group_id)

  
  def perform
    total_uploaded = 0
    total_readed = 0
    total_wrong = 0
    count = 0

    
    Notification.new(:msg => "uploading clients", :type_msg => 'clients', :user_id => self.user_id).save
    tinit = Time.now

    ::CSV.foreach(self.file[:path]) do |row|
      next if row[1].nil?

      total_readed += 1
      data = {:fullname => row[0].to_s.strip, :phonenumber => row[1].to_s.gsub(/[^0-9,]+/, ''), :campaign_id => self.campaign_id, :group_id => self.group_id}

      next if Client.where(data).exists? #si existe se omite
      
      #7 y 10 digitos
      if data[:phonenumber].size > 10 || data[:phonenumber].size < 6
        total_wrong += 1
        next
      end
      
      client = Client.new(data)
      if client.save
        total_uploaded += 1
      else
        total_wrong += 1
      end
    end
    tend = Time.now
    msg = 'Uploaded %d and wrongs %d clients with total %d readed in %d seconds ' % [total_uploaded, total_wrong,  total_readed, (tend - tinit)]
    Notification.new(:msg => msg, :type_msg => 'clients', :user_id => self.user_id).save
    
    
  end
  
end
