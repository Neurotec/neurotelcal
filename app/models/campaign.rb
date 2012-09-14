# -*- coding: utf-8 -*-
#La campana representa un conjunto de clientes a llamar
#y un grupo de mensajes a comunicarles.
#La campana puede estar en los estados:
# ::START:: la campana realiza llamadas
# ::PAUSE:: se pausa en el ultimo cliente, pero el servicio haun esta activado
# ::END:: se detiene por complete las llamadas
#Mirar /lib/neurotelcalservice.rb para mas detalles, tambien pueden
#mirar Campaign#process.
class Campaign < ActiveRecord::Base
  STATUS = { 'START' => 0, 'PAUSE' => 1, 'END' => 2}

  attr_accessible :description, :name, :status, :entity_id
  
  validates :name, :presence => true, :uniqueness => true
  validates :entity_id, :presence => true
  has_many :resource, :dependent => :delete_all
  has_many :client, :dependent => :delete_all
  has_many :plivo, :dependent => :delete_all
  has_many :group, :dependent => :delete_all
  belongs_to :entity

  def pause?
    #Se reconsulta para obtener ultimo estado
    r = Campaign.select('status').where(:id => self.id).first.status
    return STATUS['PAUSE'] == r
  end

  def end?
    r = Campaign.select('status').where(:id => self.id).first.status
    return STATUS['END'] == r
  end
  

  def start?
    r = Campaign.select('status').where(:id => self.id).first.status
    return STATUS['START'] == r
  end

  #Se verifica si se puede llamara a un cliente
  #con un determinado mensaje y un calendario de mensaje.
  #El objetivo primordial es llamar las veces que sea necesario
  #el cliente hasta que se obtenga una respuesta de que contesto, por cada
  #'falla' en la llamada al cliente ha este se le baja la prioridad mirar Client#update_priority_by_hangup_cause
  #o bien se le aumente si contesto satisfactoriamente esta prioridad es acumulativa al cliente mirar atributo Client#prority
  #Teniendo como logica de funcionamiento:
  # * si es mensaje anonimo llamar de una
  # * si es un cliente con un numero invalido no se llama
  # * si ya se marco para el menasje no se llama
  # * si ya se esta marcando no se llama
  # * si ha fallado se reintenta las veces indicadas por mensaje
  #
  #::client:: cliente a llamar
  #::message:: mensaje a ser comunicado
  #::message_calendar:: calendario de mensaje usado en caso de haber
  #::return:: boolean indicando si se pudo o no realizar la llamada
  def can_call_client?(client, message, message_calendar = nil)
    called = false
    if not message.anonymous and client.group.messages_share_clients
      ncalls = Call.where(:message_id => client.group.id_messages_share_clients, :client_id => client.id).count
    else
      ncalls = Call.where(:message_id => message.id, :client_id => client.id).count
    end
    #@todo agregar exepction
    if ncalls > 0
      considera_contestada = PlivoCall::ANSWER_ENUMERATION
      
      #logger.debug("Grupo comparte mensajes?" + client.group.messages_share_clients.to_s )
      
      if not message.anonymous and client.group.messages_share_clients 
        message_id = client.group.id_messages_share_clients
      else
        message_id = message.id
      end
      
      #no hay que botar escape ni modo de ubicar el numero
      return false if Call.where(:client_id => client.id).where("hangup_enumeration IN (%s)" % PlivoCall::REJECTED_ENUMERATION.map {|v| "'%s'" % v}.join(',')).count > 0
      #ya se marco
      return false if Call.where(:message_id => message_id, :client_id => client.id).where(:hangup_enumeration => PlivoCall::ANSWER_ENUMERATION).count > 0
      return false if Call.in_process_for_message_client?(message_id, client.id).exists?
      
      #se vuelve a marcar desde la ultima marcacion
      begin
        calls_faileds = Call.where(:message_id => message_id, :client_id => client.id).where("hangup_enumeration NOT IN (%s)" % PlivoCall::ANSWER_ENUMERATION.map {|v| "'%s'" % v}.join(',')).count
        #logger.debug('calls faileds %d for client %d' % [calls_faileds, client.id])
        call_failed = Call.where(:message_id => message_id, :client_id => client.id).where("hangup_enumeration NOT IN (%s)" % PlivoCall::ANSWER_ENUMERATION.map {|v| "'%s'" % v}.join(',')).order('terminate').reverse_order.first if calls_faileds > 0

        if calls_faileds >= message.retries
          #logger.debug('client %d priority to seconds %d' % [client.id, client.priority_to_seconds_wait])
          if not (Time.now >= Time.parse(call_failed.terminate.to_s) + client.priority_to_seconds_wait)
            return false
          else
            #se actualiza prioridad a cliente para marcacion
            client.update_priority_by_hangup_cause(call_failed.hangup_enumeration)
          end
        end
        
      rescue Exception => e
        logger.error('Error seen calls faileds. %s' % e.message)
      end
      
    end
    
    return true
  end
  
  #Para mandar lotes de llamadas
  #::deprecation:: acutalmente no esta confirmado su uso correcto
  def call_clients(clients, message)
    self.plivo.all.each { |plivo|
      begin
        plivo.call_clients(clients, message)
        return true
      rescue PlivoChannelFull => e
        logger.debug("Plivo id %d full trying next plivo" % plivo.id)
        next
      end
    }
    return false
  end
  
  #Campaign llama cliente, buscando un espacio disponible entre sus servidores plivos
  def call_client(client, message, message_calendar = nil)
    raise PlivoNotFound, "There is not plivo server, first add one" unless self.plivo.exists?
    called = false
    self.plivo.all.each { |plivo|
      begin
        plivo.call_client(client, message, message_calendar)
        called = true
        break
      rescue PlivoChannelFull => e
        logger.debug("Plivo id %d full trying next plivo" % plivo.id)
        next
      end
    }
    
    raise PlivoCannotCall, "cant find plivo to call" unless called
    return called
  end
  
  
  #Procesa mensaje y realiza las llamadas indicadas
  #@todo cachear consultas ya que se realizan muchas
  def process
    self.group.all.each do |group|
      
      #si esta pausado no se realiza las llamadas
      next if pause?
      fibers = []
 
      group.message.all.each do |message|
        #se termina en caso de forzado, y espera la ultima llamada
        return false if end?
      
        fibers << Fiber.new {
          sleep 1 while pause? #si se pausa la campana se espera hasta que se despause
          
          #si ya se marcaron todos los clientes posibles se salta
          if message.done_calls_clients? and not message.anonymous
            #logger.debug("Mensaje %d done calls jumping" % message.id)
            next
          end
          

          #logger.debug("Time ahora (%s) message_call (%s) message_end (%s)" % [Time.now.to_s, Time.zone.parse(message.call.to_s), Time.parse(message.call_end.to_s)])
          #se omite mensaje que no esta en fecha de verificacion
          next if Time.now < message.call or Time.now > message.call_end

          #canales extras para cumplir con los calendarios que se activen
          use_extra_channels =  extra_channels(message)
          
          #logger.debug("Campaign#Process: Revisando mensaje %s inicia %s y termina %s" % [message.name, message.call.to_s, message.call_end.to_s])
          
          #cantidad de llamadas iniciadas
          count_calls = 0

          #Se llama a los clientes hasta que se cumpla el limite de canales simultaneos o
          #se termina los clientes esperados
          group.client.all.each do |client|
            #logger.debug("Campaign#Process: Para cliente %s en grupo %s" % [client.fullname, group.name])
            #si es marcacion directa anonima
            if message.anonymous
              next call_client(client, message) 
            end
            
            #se espera que la ultima llamada se ade este mensaje
            #sino se omite cliente y se deja para que lo preceso el mensaje
            #al que corresponde
            if Call.where(:client_id => client.id).exists? and client.group.messages_share_clients
              if not Call.where(:message_id => message.id, :client_id => client.id).exists? 
                next
              elsif (Call.where(:message_id => message.id, :client_id => client.id).count - Call.not_answered_for_message_client(message.id, client.id).count) >= message.max_clients
                break
              end
            end
            
            if client.group.messages_share_clients
              message_id = client.group.id_messages_share_clients
            else
              message_id = message.id
            end
            
            #se salta si ya esta en proceso
            if Call.in_process_for_message_client?(message_id, client.id).exists?
              count_calls += Call.in_process_for_message_client?(message_id, client.id).count
              next
            end
            
            #se termina este mensaje si ya se hicieron todas las esperadas
            if Call.done_calls_message(message.id).count + count_calls >=  message.max_clients
              break
            elsif message.max_clients > 0 and count_calls >= message.max_clients
              break
            end
            
            #logger.debug('Count trying done calls %d for message %d max clients %d' % [count_calls, message.id, message.max_clients])
            #se busca el calendario para iniciar marcacion
            #logger.debug("Campaign#Process: Se busca en calendario")
            message.message_calendar.all.each do |message_calendar|
              #se detiene marcacion si ya se realizaron todas las llamadas contestadas
              if Time.now >= message_calendar.start and  Time.now <= message_calendar.stop
                if message_calendar.max_clients > 0 and (Call.where(:message_calendar_id => message_calendar.id, :hangup_enumeration => PlivoCall::ANSWER_ENUMERATION).count + Call.where(:message_calendar_id => message_calendar.id, :terminate => nil).count) >= message_calendar.max_clients 
                  count_calls += message.max_clients #se saca a la fuerza
                else
                  limit_of_channels = 0
                  #si se pone canales a cero los canales se asignan
                  #automaticamente segun los disponibles
                  if message_calendar.channels == 0
                    limit_of_channels = use_extra_channels
                  else
                    limit_of_channels = message_calendar.channels
                  end
                  
                  if count_calls >= limit_of_channels #se limita los canales por calendario
                    count_calls += message.max_clients
                  else
                    if can_call_client?(client, message, message_calendar)
                      count_calls += 1 if call_client(client, message, message_calendar)
                    end
                  end
                end
                break
              end
            end
          end
        }
      end #end group
      fibers.each(&:resume)
    end
    
  end

  private

  #Esto selecciona automaticamente los canales ha usar en el mensaje
  #en base a la cantidad de llamadas esperadas, logradas y faltantes
  #Osea en caso de faltar poco tiempo para terminar y hay canales disponibles
  #y hay muchas llamadas se utilizan los canales en proporcion a lo necesario para
  #cumplir con el max_clients del calendario.
  #::return:: int cantidad a ampliar para llamar
  def extra_channels(message)
    message_calendar_total_channels = 0
    #conteo de los cupos asignados para no usarlos
    Group.where(:campaign_id => id).each do |group|
      group.message.each do |message|
        message.message_calendar.each {|ms| message_calendar_total_channels += ms.channels }
      end
    end
    
    #cantidad de canales necesarios
    need_channels = 0
    message.message_calendar.each do |message_calendar|
      next if Time.now < message_calendar.start or Time.now > message_calendar.stop
      next unless message_calendar.time_expected_for_call > 0
      #llamadas contestadas
      calls_answered = Call.answered_for_message(message.id).count
      logger.debug('extra_channels: calls_answered %d' % calls_answered)

      #llamadas esperedas o bien los clientes que debe hacer el calendario
      calls_expected = message_calendar.max_clients
      logger.debug('extra_channels: calls_expected %d' % calls_expected)

      #llamadas permitias desde plivo
      plivo_total_channels = plivo.all.size > 1 ? plivo.all.inject{|s,v| s.channels + v.channels} : plivo.first.channels
      plivo_using_channels = plivo.all.size > 1 ? plivo.all.inject{|s,v| s.using_channels + v.using_channels} : plivo.first.using_channels
      logger.debug('extra_channels: plivo_total_channels %d , plivo_using_channels %d' % [plivo_total_channels, plivo_using_channels])

      #cantidad de canales disponibles despues de los ya usados y los separados
      channels_availables = plivo_total_channels - (plivo_using_channels + message_calendar_total_channels)
      logger.debug('extra_channels: channels_availables %d' % channels_availables)

      #llamada restantes para limite
      calls_to_complete = calls_expected - calls_answered
      logger.debug('extra_channels: calls_to_complete %d' % calls_to_complete)

      #tiempo restante para limite
      seconds_to_complete = message_calendar.stop - Time.now
      logger.debug('extra_channels: seconds_to_complete %d' % seconds_to_complete)

      #canales para completar
      begin
        channels_to_complete = calls_to_complete / (seconds_to_complete / message_calendar.time_expected_for_call)
        logger.debug('extra_channels: channels_to_complete %d' % channels_to_complete)
        nchannels = channels_availables - channels_to_complete.floor
        need_channels += channels_availables > channels_to_complete ? channels_to_complete : channels_availables
      rescue ZeroDivisionError => e
        #e.backtrace.each { |line| logger.error line}
      rescue Exception => e
        e.backtrace.each { |line| logger.error line}
      end
    end
    logger.debug('extra_channels:Needing extra channels %d' % need_channels)
    return need_channels
  end
  
end
