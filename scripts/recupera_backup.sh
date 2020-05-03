#!/bin/bash
EPREFIX="/opt/apps/postgres/release/bin/"
USUARIO="postgres"
HOST_BACKUP="10.0.0.40"
LOG="/var/log/postgres_restore_timeline.log"
TIMESTAMP=$(date +%Y%m%d%H%M)
BASE_BACKUP="/dados/backup/pgsql"
FILES="/opt/postgres_scripts/pgsql_timelines"
RESTORE_COMMAND="/opt/postgres_scripts/restore_command"
PGDATA="/dados/postgres/data/5433"
USERID="-MeuChatID"
KEY="222222222:hfjyr8u5TGydydhddddUJGokTGERS%TGBDD"
TIMEOUT="10"
URL="https://api.telegram.org/bot${KEY}/sendMessage"

alias cp=cp

# Diretorio Current
cd $(dirname $0)

# Funcoes
MOSTRA () {
        echo $(date +%Y-%m-%d-%H:%M:%S) - $@
}

# Checa se a variavel ULTIMO_BACKUP foi definida 
if [[ -z $ULTIMO_BACKUP ]]
then
    MOSTRA "A variavel Ultimo Backup nao foi definida. Processo abortado favor checar o arquivo backup_a_restaurar.sh" >> ${LOG} 
    echo "--------------------------------" >> ${LOG}
    echo "" >> ${LOG}
    exit 1;
fi

# Iniciando uma nova verificacao de Backup.
MOSTRA Iniciando processo de recovery timeline Postgres - ${ULTIMO_BACKUP} >> ${LOG}

# Para o serviço d Postgres se ele estiver rodando
${EPREFIX}/pg_ctl stop -D ${PGDATA}/$(find ${PGDATA} -maxdepth 1 -mindepth 1 -name '[0-9]*' -exec basename {} \;) -m fast >/dev/null 2>&1
sleep 5
PROCESSO_RUNNING=$(sudo lsof -iTCP -sTCP:LISTEN -P -n | grep 5433 | head -1 | awk {'print $2'})

# Checa se o processo foi morto
if [[ -z ${PROCESSO_RUNNING} ]]
then
   MOSTRA "O serviço do PostgreSQL na porta 5433 foi parado com sucesso." >> ${LOG}
else
   MOSTRA "O Processo do PostgreSQL na porta 5433 não pode ser encerrado." >> ${LOG}
   echo "--------------------------------" >> ${LOG}
   echo "" >> ${LOG}
   TEXT=$(echo "O Serviço do Postgres na porta 5433 não pode ser interrompida, maiores informações em: ${LOG}")   
   curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=${TEXT}" ${URL} > /dev/null
   exit 1;
fi

# Remove o PGDATA (TIMESTAMP) 
rm -rf $(find ${PGDATA} -maxdepth 1 -mindepth 1 -name '[0-9]*' -exec echo {} \;)
sleep 5

# Transferindo BaseBackup.
MOSTRA "Copiando o Full Backup ${ULTIMO_BACKUP}" >> ${LOG}
scp -r ${USUARIO}@${HOST_BACKUP}:${BASE_BACKUP}/${ULTIMO_BACKUP} ${PGDATA}

# Limpando arquivos
rm -f ${PGDATA}/${ULTIMO_BACKUP}/backup_label 
rm -f ${PGDATA}/${ULTIMO_BACKUP}/recovery.done 
rm -f ${PGDATA}/${ULTIMO_BACKUP}/pg_hba.conf
rm -f ${PGDATA}/${ULTIMO_BACKUP}/postgresql.conf 

# Copia restore command que sera utilizado.
[[ ! -d ${RESTORE_COMMAND} ]] && mkdir -p ${RESTORE_COMMAND}
cp ${FILES}/scripts/restore_command_timelines.sh ${RESTORE_COMMAND} 

# Copiando arquivos personalizados
MOSTRA "Copiando os FILES personalizados - pg_hba.conf, postgresql.conf, recovery.conf" >> ${LOG}
cp ${FILES}/confs/*.conf ${PGDATA}/${ULTIMO_BACKUP}

# Iniciando Postgres
MOSTRA "Iniciando o Cluster em $(hostname -a) - Porta 5433" >> ${LOG}
${EPREFIX}/pg_ctl start -D ${PGDATA}/${ULTIMO_BACKUP} -l ${PGDATA}/${ULTIMO_BACKUP}/serverlog >/dev/null
PROCESSO_RUNNING=$(sudo lsof -iTCP -sTCP:LISTEN -P -n | grep 5433 | head -1 | awk {'print $2'})

# Checa se a variavel não está vazia, ou seja, serviço está rodando.
if [[ -z ${PROCESSO_RUNNING} ]]
then
    MOSTRA "O PostgreSQL na porta 5433 não pode inicializado, verifique logs: ${PGDATA}/${ULTIMO_BACKUP}/serverlog" >> ${LOG}
    echo "--------------------------------" >> ${LOG}
    echo "" >> ${LOG}
    TEXT=$(echo "O Serviço do postgres na porta 5433 não foi iniciado, maiores informações em: ${LOG}")   
    curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=${TEXT}" ${URL} >/dev/null
    exit 1;
fi

POSTGRES_TA_NO_AR() {

   kill -0 ${PROCESSO_RUNNING}
   [[ $? -eq 0 ]] && export POSTGRES_RUNNING=true || export POSTGRES_RUNNING=false

   if [[ ${POSTGRES_RUNNING} == false ]]
   then
          MOSTRA "O PostgreSQL na porta 5433 parou de forma inesperada, verifique logs: ${PGDATA}/${ULTIMO_BACKUP}/serverlog" >> ${LOG}
          echo "--------------------------------" >> ${LOG}
          echo "" >> ${LOG}          
          TEXT=$(echo "O Postgres na porta 5433 parou de forma inesperada, maiores informações em: ${LOG}")   
          curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=${TEXT}" ${URL} >/dev/null
          exit 1;
   fi
}

# Aplicando os archives Logs
PROGRESSO=true
while ${PROGRESSO}
do
   # Checa se o serviço ta rodando.
   POSTGRES_TA_NO_AR

   if [[ -e ${PGDATA}/${ULTIMO_BACKUP}/recovery.conf ]]
   then
      egrep -o "recovery has paused" ${PGDATA}/${ULTIMO_BACKUP}/serverlog >/dev/null
      if [[ $? -eq 0 ]]
      then
         PROGRESSO=false
         MOSTRA "Archives aplicados com sucesso" >> ${LOG}
      fi
   else
      sleep 300
   fi

done

# Para o servico do Postgres para renomear o arquivo recovery.conf
MOSTRA "Parando Postgres para renomear recovery.conf" >> ${LOG}
${EPREFIX}/pg_ctl stop -D ${PGDATA}/$(find ${PGDATA} -maxdepth 1 -mindepth 1 -name '[0-9]*' -exec basename {} \;) -m fast >/dev/null 2>&1
sleep 5
PROCESSO_RUNNING=$(sudo lsof -iTCP -sTCP:LISTEN -P -n | grep 5433 | head -1 | awk {'print $2'})

# Checa se o Postgres foi interrompido com sucesso
kill -0 ${PROCESSO_RUNNING}
[[ $? -eq 0 ]] && export POSTGRES_RUNNING=true || export POSTGRES_RUNNING=false

# Renomeando arquivo recovery.conf para recovery.done, e necessário que o Postgres esteja parado.
if [[ ${POSTGRES_RUNNING} == false ]]
then
    mv ${PGDATA}/${ULTIMO_BACKUP}/recovery.conf ${PGDATA}/${ULTIMO_BACKUP}/recovery.done
    if [[ $? -eq 0 ]]
    then
        ${EPREFIX}/pg_ctl start -D ${PGDATA}/${ULTIMO_BACKUP} -l ${PGDATA}/${ULTIMO_BACKUP}/serverlog >/dev/null
        PROCESSO_RUNNING=$(sudo lsof -iTCP -sTCP:LISTEN -P -n | grep 5433 | head -1 | awk {'print $2'})
    fi
else
    MOSTRA "Não pode renomear arquivo de recovery.conf para renomear recovery.done" >> ${LOG}
    echo "--------------------------------" >> ${LOG}
    echo "" >> ${LOG}          
    TEXT=$(echo "O Postgres na porta 5433 parou de forma inesperada, maiores informações em: ${LOG}")   
    curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=${TEXT}" ${URL} >/dev/null
    exit 1;    
fi

if [[ ! -z ${PROCESSO_RUNNING} ]]
then
    MOSTRA "Archives foram aplicados com sucesso para restrore do backup ${ULTIMO_BACKUP}" >> ${LOG}
    MOSTRA "[SUCESSO]" >> ${LOG}
    echo "Serviço => Recovery Timeline" >/tmp/telegram.txt
    echo "Host      => 10.0.0.60" >>/tmp/telegram.txt 
    echo "Port      => 5433" >>/tmp/telegram.txt 
    echo "Banco   => bancoXXX" >>/tmp/telegram.txt 
    echo "Backup  => ${ULTIMO_BACKUP}" >>/tmp/telegram.txt
    echo "Status  => [SUCESSO]" >>/tmp/telegram.txt
    echo "Data     => $(date +%Y/%m/%d" "%H:%M:%S)" >>/tmp/telegram.txt

else
    MOSTRA "O Backup está comprometido, os archives não foram aplicados, verifique logs: ${PGDATA}/${ULTIMO_BACKUP}/serverlog " >> ${LOG}
    MOSTRA "[ERRO]" >> ${LOG}
    echo "--------------------------------" >> ${LOG}
    echo "" >> ${LOG}
    echo "ERRO => O Postgres não aplicou os archives! Maiores informações em: ${LOG}" >/tmp/telegram.txt
fi

# Notificacao Telegram    
curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=$(cat /tmp/telegram.txt)" ${URL} > /dev/null
echo "--------------------------------" >> ${LOG}
echo >> ${LOG}
