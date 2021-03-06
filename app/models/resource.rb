# -*- coding: utf-8 -*-
require 'digest'

class Resource < ActiveRecord::Base
  default_scope order('created_at DESC')
  TYPES = ["audio", "correoe"]

  attr_accessible :campaign_id, :file, :name, :type_file, :created_at, :updated_at

  validates :name, :type_file, :file, :presence => true
  validates :name, :uniqueness => true
  validates :type_file, :inclusion => TYPES
  validate :recurso_es_valido
  before_save :archivo_local

  #pertenece a campañas
  belongs_to :campaign

  def name_file
    File.basename(self.file)[32..-1]
  end

  def destroy
    begin
    File.unlink(self.file)
    rescue
    end
    super()
  end

  #Guardo el archivo enviado en carpeta resources/audio o resources/documento
  def archivo_local

    if file.is_a? ActionDispatch::Http::UploadedFile
      uploaded_io = file
      uploaded_io.original_filename= uploaded_io.original_filename.gsub(/[^0-9a-zA-z.]/, '')

      name_file = (Digest::MD5.hexdigest(name+uploaded_io.original_filename) + uploaded_io.original_filename).gsub(/[^0-9a-zA-Z.]/, '')

      #relativo a Rails.root
      short_file = File.join('public', 'resources', type_file, name_file)
      path_file = Rails.root.join('public', 'resources', type_file, name_file)

      FileUtils.mv uploaded_io.tempfile, path_file, force: true
      FileUtils.chmod 0777, path_file

      self.file = short_file

    end
  end
  
  ###VALIDACIONE PERSONALES
  def recurso_es_valido

    #valida el archivo enviado
    #corresponda al tipo indicado y sea soportado
    if file
      #el modshout usado por plivo en freeswitch solo soporta mp3
      #ni audio/x-wav, audio/ogg
      mime_audio = ['audio/mpeg', 'audio/wav', 'audio/x-wav']
      mime_document = ['application/pdf', 'application/vnd.oasis.opendocument.text']
      mime_correoe = ['text/plain']
      case type_file
      when 'correoe'
        unless mime_correoe.include? file.content_type
          errors.add(:file, 'Archivo no compatible con correo-e')
        end
      when 'audio'
        case file
        when ActionDispatch::Http::UploadedFile
          unless mime_audio.include? file.content_type
            errors.add(:file, 'Archivo no compatible con tipo audio')
          end
        end
      when 'documento'
        unless mime_document.include? file.content_type
          errors.add(:file, 'Archivo no compatible con tipo documento')
        end
      end
      
    end
  end

end
