# Copyright (C) 2012 Bit4Bit <bit4bit@riseup.net>
#
# This file is part of NeuroTelCal
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
require 'csv'

class ClientsController < ApplicationController
  # GET /clients
  # GET /clients.json
  def index
    #activo session[:campaign_id] para saber en cual campana se esta
    if params[:campaign_id]
      @campaign_id = params[:campaign_id].to_i
      session[:campaign_id] = @campaign_id
    else
      @campaign_id = session[:campaign_id]
    end

    @campaign = Campaign.find(@campaign_id)

    @clients = Client.where(:campaign_id => @campaign_id).paginate :page => params[:page]
 
    respond_to do |format|
      format.html # index.html.erb
      format.json { render :json => @clients }
    end
  end

  # GET /clients/1
  # GET /clients/1.json
  def show
    @client = Client.find(params[:id])
    @client.campaign_id = session[:campaign_id]

    respond_to do |format|
      format.html # show.html.erb
      format.json { render :json => @client }
    end
  end

  # GET /clients/new
  # GET /clients/new.json
  def new
    @client = Client.new
    @client.campaign_id = session[:campaign_id]
    @groups = Group.where("campaign_id = ?", @client.campaign_id).all.map {|u| [u.name, u.id] }
    
    respond_to do |format|
      format.html # new.html.erb
      format.json { render :json => @client }
    end
  end

  # GET /clients/1/edit
  def edit
    @client = Client.find(params[:id])
    @client.campaign_id = session[:campaign_id]
    @groups = Group.all.map {|g| [g.name, g.id]}
  end

  # POST /clients
  # POST /clients.json
  def create
    @client = Client.new(params[:client])
    @client.campaign_id = session[:campaign_id]
    @groups = Group.all.map {|g| [g.name, g.id]}

    respond_to do |format|
      if @client.save
        format.html { redirect_to @client, :notice => 'Client was successfully created.' }
        format.json { render :json => @client, :status => :created, :location => @client }
      else
        format.html { render :action => "new" }
        format.json { render :json => @client.errors, :status => :unprocessable_entity }
      end
    end
  end

  # PUT /clients/1
  # PUT /clients/1.json
  def update
    @client = Client.find(params[:id])
    @client.campaign_id = session[:campaign_id]
    @groups = Group.all.map {|g| [g.name, g.id]}

    respond_to do |format|
      if @client.update_attributes(params[:client])
        format.html { redirect_to @client, :notice => 'Client was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render :action => "edit" }
        format.json { render :json => @client.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /clients/1
  # DELETE /clients/1.json
  def destroy
    @client = Client.find(params[:id])
    @client.campaign_id = session[:campaign_id]
    @client.destroy

    respond_to do |format|
      format.html { redirect_to clients_url }
      format.json { head :no_content }
    end
  end

  def new_upload_massive
    @groups = Group.where(:campaign_id => session[:campaign_id])
    
    respond_to do |format|
      format.html 
    end
  end
  
  def create_upload_massive
    @groups = Group.where(:campaign_id => session[:campaign_id])
    print params
    total_uploaded = 0
    total_readed = 0
    total_wrong = 0
    errors = []
    count = 0
    override = params[:override] || false
    flash.delete(:error)
    begin
      Notification.new(:msg => "uploading clients %s" % params[:list_clients].original_filename, :type_msg => 'clients', :user_id => session[:user_id]).save
      tinit = Time.now
      ::CSV.parse(params[:list_clients].tempfile) do |row|
        if row[1].nil?
          raise I18n.t('need_phonenumber',true)
        end
        total_readed += 1
        data = {:fullname => row[0].to_s.strip, :phonenumber => row[1].to_s.gsub(/[^0-9]+/, ''), :campaign_id => session[:campaign_id], :group_id => params[:group_id]}
        if override
          next if Client.where(data).exists? #si existe se omite
        end
        
        #7 y 10 digitos
        if data[:phonenumber].size > 10 || data[:phonenumber].size < 6
          total_wrong += 1
          next
        end

        client = Client.new(data)
        if client.save
          total_uploaded += 1
        else
          errors << client.errors.full_message
          total_wrong += 1
        end
      end
      tend = Time.now
      msg = 'Uploaded %d and wrongs %d clients with total %d readed in %d seconds ' % [total_uploaded, total_wrong,  total_readed, (tend - tinit)]
      Notification.new(:msg => msg, :type_msg => 'clients', :user_id => session[:user_id]).save
      flash[:notice] = msg
    rescue Exception => e
      if params[:list_clients].nil?
        flash[:error] = I18n.t('not_uploaded_file')
      else
        flash[:error] = e.message
      end
      

    end

    unless errors.empty?
      flash[:error] = errors.join('<br />')
    end

    respond_to do |format|
      format.html { render :action => 'new_upload_massive'}
    end
  end
  
end
