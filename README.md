# Restaurando PostgreSQL Timeline via Gitlab

Constantemente preciso voltar o estado do Banco até uma determinada Timeline para realizar algum tipo de auditoria. Para agilizar esse processo, criei um ```pipeline``` que volta o ```basebackup``` mais próximo da Timeline desejada e aplica-se os ```Archives Logs``` até que o banco fique em um estado consistênte na data desejada.

## Ferramentas Necessárias

Para reproduzir esse tutorial em seu ambiente será necessário os seguintes produtos:

- Gitlab
- Runner Docker - Gitlab
- Servidor Linux com PostgreSQL Instalado 

## Cenário do Banco em Produção

O serviço do PostgreSQL guarda os ```Archives Logs``` em um servidor NFS, onde o apenas o servidor de produção pode escrever (RW) no compartilhamento. O ```servidor de validação``` apenas lê ( RO ) o compartilhamento.

![Estrutura NFS - PostgreSQL](https://i.ibb.co/sQzKRCG/01-nfs.jpg)

## 1ª Etapa - Configuração  Banco em Produção

Configurações necessárias para que o PostgreSQL faça ```Archives Logs```.

### Fstab dos Servidores

As máquinas envolvidas no processo montam automaticamente o compartilhamento no boot do S.O. 

Ex: ```/etc/fstab``` servidor Produção

```bash
# Servidor NFS => 10.0.0.1
10.0.0.1:/nfs 	  /mnt/archivelogs	  nfs     rw,defaults
```

Ex: ```/etc/fstab``` servidor Validação

```bash
# Servidor NFS => 10.0.0.1
10.0.0.1:/nfs 	  /mnt/archivelogs	  nfs     ro,defaults
```

Criar a estrutura de diretório após a unidade remota estar montada.

```bash
postgres@postgres:/$ mkdir -p /mnt/archivelogs/10.3
postgres@postgres:/$ ln -svf /mnt/archivelogs/10.3 /mnt/archivelogs/release
```

***Obs.: Para evitar transtornos com Permissões, em ambas as máquinas o UID e GID do usuário Postgres devem ser os mesmos.***

### Postgresql.conf ( Produção )

```
# Hot Standby
wal_level = hot_standby
synchronous_commit = on
wal_buffers = 4MB
wal_writer_delay = 200ms
archive_mode = on
archive_command = '/scripts/archive.sh %p %f'
archive_timeout = 3600
wal_sender_timeout = 5000
max_wal_senders = 5
wal_keep_segments = 32
hot_standby = on
max_standby_archive_delay = -1
max_standby_streaming_delay = -1
wal_receiver_status_interval = 2s
hot_standby_feedback = on
```

### Pg_hba.conf ( Produção )

```
# replication privilege.
local     replication     all                                     trust
host      replication     postgres        127.0.0.1/32            trust
host      replication     postgres        10.0.0.10/32            trust
host      replication     postgres        10.0.0.20/32            trust
host      replication     postgres        10.0.0.30/32            trust
host      replication     postgres        ::1/128                 trust
```

### Archive.sh ( Produção )

O script abaixo fará ```Log Flush``` no compartilhamento do NFS. Ele é capaz de checar se o NFS está acessível e caso o mesmo não esteja, um bot já pre-configurado, enviará uma notificação via telegram. 

***Obs.: Substitua as viariáveis USERID e KEY para receber as notificações via Telegram.***

```bash
#!/bin/bash

p=$1
f=$2
CODE=1
DIR="/mnt/archivelogs/release"

# Funcao Telegram
telegram(){
  USERID="ChatID"
  KEY="Token"
  URL="https://api.telegram.org/bot${KEY}/sendMessage"
  DATA=$(date +%Y"/"%m"/"%d" "%H":"%M":"%S)
  MSG="/tmp/msg.txt"
  TIMEOUT="10"
  echo "---- ARCHIVE LOG ERRO ❌ ----- " > ${MSG}
  echo "Diretório Archives Desmontado" >> ${MSG}
  echo "Servidor: 10.0.0.30" >> ${MSG}
  echo "DateTime: ${DATA}" >> ${MSG}
  echo "Executar Comando: mount -a" >> ${MSG}
  curl -s --max-time ${TIMEOUT} -d "chat_id=${USERID}&disable_web_page_preview=1&text=$(cat ${MSG})" ${URL} > /dev/null
}

if [[ -d ${DIR} ]]
then
    # Testa se NFS esta acessivel
    ( touch ${DIR}/1 2>/dev/null && rm -f ${DIR}/1; ) && export NFS_OK=true  || export NFS_OK=false

    if [[ ${NFS_OK} == true ]]
    then
        cp $p ${DIR}/$f
        CODE=$?
     else
        # NFS está montado, mas não está acessível.
        telegram
     fi
else
    # Unidade remota não está montada verificar NFS.
    telegram
fi

exit $CODE     
```

## Estrutura do Backup

***Servidor de Backup -> 10.0.0.40***

Todo Backup é armazenado em um outro servidor chamado de ```Servidor de Backup```, esse servidor que dispara e retém os backup produzidos pelo postgres. Ele possui uma rotina no cron para ser executado semanalmente.

```bash
dir="/dados/backup/pgsql/$(date +%Y%m%d%H%M%S)"
mkdir -p ${dir}
/opt/app/pgsql/bin/pg_basebackup --wal-method=fetch -l "Backup Production" -P -D ${dir} -h 10.0.0.30 -U postgres
```

Se listarmos o diretório de Backup ```/dados/backup/pgsql``` encontraremos os seguintes backups:

```bash
drwx------ 18 postgres   postgres   4096 Feb 20 21:39 20200220202020
drwx------ 18 postgres   postgres   4096 Mar 10 01:51 20200320202020
drwx------ 18 postgres   postgres   4096 Apr  5 21:46 20200405202020
drwx------ 18 postgres   postgres   4096 Apr 13 21:44 20200413202020
```

## 2ª Etapa - Configurando Servidores ( Comunicação entre servidores ).

Agora precisamos permitir que as máquinas ***Servidor Backup -> 10.0.0.40*** e ***Servidor Validação -> 10.0.0.60*** possam se comunicar via SSH sem senha. Para isso, vamos gerar uma chave no ```Servidor de Validação``` e autoriza-la no ```Servidor de Backup```, isso permitirá que que o servidor de validação possa fazer um ```scp``` do base backup necessário de forma transparente.

### Permissoes especiais ( sudo )

***Obs.: Talves seja necessario instalar esses pacote no seu S.O***
- lsof
- screen

```bash
postgres ALL=(ALL) NOPASSWD: /sbin/lsof
```

### Diretórios e Arquivos necessários
```bash
root@validacao:/# touch /var/log/postgres_restore_timeline.log
root@validacao:/# chown postgres. /var/log/postgres_restore_timeline.log
root@validacao:/# mkdir -p /opt/postgres_scripts/pgsql_timelines
root@validacao:/# chown postgres. /opt/postgres_scripts
root@validacao:/# mkdir -p /dados/postgres/data/5433
root@validacao:/# chown -R postgres. /dados
```

### Autorizando Servidor de Validação comunicar com Servidor de Backup

No servidor de Validação execute:

```bash
root@validacao:/# su - postgres
postgres@validacao:/home/postgres$ ssh-keygen
Generating public/private rsa key pair.
Enter file in which to save the key (/home/postgres/.ssh/id_rsa):
Created directory '/home/postgres/.ssh'.
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /home/postgres/.ssh/id_rsa
Your public key has been saved in /home/postgres/.ssh/id_rsa.pub
The key fingerprint is:
SHA256:CpFhw5adDLrHHb2kTtLZoxvV7NrwdVovNId5kLmioAg postgres@validacao
The key's randomart image is:
+---[RSA 3072]----+
|   .== .         |
|   o+++.         |
|  ..o . o      o |
|   o + * +    +  |
|  . = * S o    = |
|  E. = +.o  . * o|
|   . .=......oo+ |
|    . .o =.. +.. |
|      . . o .  ..|
+----[SHA256]-----+
```

O comando acima irá produzir 2 arquivos ***~/.ssh/id_rsa.pub*** e ***~/.ssh/id_rsa*** . Copie a chave pública ```id_rsa.pub``` para o servidor de Backup.

```bash
postgres@validacao:/home/postgres$ cat ~/.ssh/id_rsa.pub

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCh/sR3/JlMrkwYL7Sg0XiHE6ZJD1VlDLd8RUpIZniqUkb2ktagLIp3F88kT/5DqFVLptKofYPJc3D5vM2XdSY/a2AlG/zCca0VF9qFhpIRuQsq36gdlWo3wZwfmfa0tvEY/1Ngtg/xGN0pbYPdIjJfXU95E2CTrBeZwDrgVQUOuqrTvczrwLdL7UFq5b1IMApDCJOWG16WFVW9WWAZIhp5TJJTL/4ZXgsIFes7DVGXZ5rZ84rBiZN6JiQRs5r+TVK1E9Yzidn1gVD3I7YzE7U6Qu3nuGLM9e12dB/wD8QR8oBvE59JhBeR0AgxCu1vwetP6cUL7VGR9/nr2zmsBb+ibg6Pb9kU3VLhDrcuFMsXmAw2rF8l9GgU+Ljdds7kFWKX34OnJ+Mo05eNue62/7auSqgabeA36PFSq38OBuCcpHK06J0IA3/vOJmPwiUtqHqPhcn9RXx6T3hq7z7vz76ISNTjHa7Kph1HuzJ2GJzdljKBa+iVN+rRHKZkNbQ9/5E= postgres@validacao
```

No servidor de Backup, onde encontra-se os backups, vamos autorizar essa chave pública. 

```bash
postgres@backup:/home/postgres$ mkdir -p ~/.ssh/
postgres@backup:/home/postgres$ chmod 700 ~/.ssh/
postgres@backup:/home/postgres$ touch ~/.ssh/authorized_keys
postgres@backup:/home/postgres$ chmod 600 ~/.ssh/authorized_keys
postgres@backup:/home/postgres$ echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCh/sR3/JlMrkwYL7Sg0XiHE6ZJD1VlDLd8RUpIZniqUkb2ktagLIp3F88kT/5DqFVLptKofYPJc3D5vM2XdSY/a2AlG/zCca0VF9qFhpIRuQsq36gdlWo3wZwfmfa0tvEY/1Ngtg/xGN0pbYPdIjJfXU95E2CTrBeZwDrgVQUOuqrTvczrwLdL7UFq5b1IMApDCJOWG16WFVW9WWAZIhp5TJJTL/4ZXgsIFes7DVGXZ5rZ84rBiZN6JiQRs5r+TVK1E9Yzidn1gVD3I7YzE7U6Qu3nuGLM9e12dB/wD8QR8oBvE59JhBeR0AgxCu1vwetP6cUL7VGR9/nr2zmsBb+ibg6Pb9kU3VLhDrcuFMsXmAw2rF8l9GgU+Ljdds7kFWKX34OnJ+Mo05eNue62/7auSqgabeA36PFSq38OBuCcpHK06J0IA3/vOJmPwiUtqHqPhcn9RXx6T3hq7z7vz76ISNTjHa7Kph1HuzJ2GJzdljKBa+iVN+rRHKZkNbQ9/5E= postgres@validacao" > ~/.ssh/authorized_keys
```

### Variáveis utillizadas no arquivo ( recupera_backup.sh )

***Obs.: Substitua as viariáveis USERID e KEY  para receber as notificações via Telegram.*** 

Essas credênciais estaram declaradas no arquivo ```scripts/recupera_backup.sh```

```
USERID="MeuChatID"
KEY="Token"
```

## 3ª Etapa - Configurando Pipeline Gitlab para executar Point In Time Recovery (PITR).

### Procedimentos feitos pelo pipeline:

- Copia o base backup definido no arquivo ***.gitlab-ci.yml*** para Servidor de Validação.
- Copia os arquivos e scripts necessários para rodar o processo de restore.
- Envia uma mensagem notificando o término do processo.

### Gerar chaves ( id_rsa e id_rsa.pub ) para Gitlab-ci comunicar com Servidor Validação.

Gere um par de chave que será utilizado para comunicação do container que executa o pipeline e o ```Servidor de Validação```. Essa chave permitirá que o container faça ```SSH``` no ```Servidor de Validação``` sem precisar de senha.

```bash
paulo@minha_maquina:/home/paulo# mkdir -p /tmp/ssh
paulo@minha_maquina:/home/paulo# ssh-keygen -t rsa -f /tmp/ssh/id_rsa
Generating public/private rsa key pair.
/tmp/ssh/id_rsa already exists.
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /tmp/ssh/id_rsa.
Your public key has been saved in /tmp/ssh/id_rsa.pub.
The key fingerprint is:
SHA256:ra2fdSUNBgrAKBZOrIO6JH8JOEHVd9myDukk3Z01MIM paulo@minha_maquina
The key's randomart image is:
+---[RSA 2048]----+
| .+o.o... ++o    |
| ++ .... E oo+   |
|oo..  o + = o +  |
|=    . = + o . o |
|.+    + S .   . o|
|=..    . +     o |
|o+ . .  . . . .  |
|. . o    . o .   |
|   .    ..o      |
+----[SHA256]-----+
```

No ```Servidor de Validação```, temos que autorizar que essa chave pública possa ser utilizada na conexão ***SSH***, pois lá que a restauração PITR acontecerá. A chave privada deverá ser armazenada no próprio Gitlab que se encarregará de disponibilizá-la para uma imagem docker na hora do deploy. Veja o ```.gitlab-ci.yml``` para entender melhor esse processos. 

Conectado no Servidor de Validação execute os seguintes passos:

```bash
postgres@validacao:/home/postgres$ mkdir -p ~/.ssh/
postgres@validacao:/home/postgres$ chmod 700 ~/.ssh/
postgres@validacao:/home/postgres$ touch ~/.ssh/authorized_keys
postgres@validacao:/home/postgres$ chmod 600 ~/.ssh/authorized_keys
postgres@validacao:/home/postgres$ echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5adMAdLax6C7fmPvCDN9Cjlj9Ykhk4qZMR86cAyAzAXEKPQDoW+ouwW7xN6s8cyMWz+jpg9MSw19pADynI0UCSQE0FNlMRGILHRmZyHkvbvnc/6lPItTAU5qRe4G0T1VYQxDksSXsDugIQOApDatdmFq3e/zYx1mMMRtU/Cotd7EusOXhuJOd6E5RcI2S0gi4klgAdyyTOJERWSW8f5iLAu+w0KJfk7/l6mu5U404v/BcTWbupnl288HBXkqQZqo+rqTS9pDDlqPhDvMvXO4kBiX1+c7FPyDbNQPt4YeNUAHufammUCSYlPL5eg8GXLhs0j5UC2Jo6nlM02NJC+n9" > ~/.ssh/authorized_keys
```

### Importar chave privada ( id_rsa ) para Gitlab-ci.

Vamos gerar um arquivo base64 com o conteúdo da chave privada que criamos no passo anterior.

```bash
paulo@minha_maquina:/home/paulo# cat /tmp/ssh/id_rsa | base64

LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dm
Vjc1M1ArcFR5TFV3Rk9ha1gKdUJ0RTlWV0VNUTVMRWw3QTdvQ0VEZ0tRMnJYWmhhdDN2ODJNZFpqREViVlB3cU
...
...
...
NSd3JSZnhUYVJhdkU2MnlRNEwKU2sxelh5VzlrWHdoaUs4QUFBQVhjR0YxYkc5QVRXRmpRbTl2YXkxUWNtOHVi
Nhfd7fdJJHYGFT76rrwRzlqWVd3QkFnTUUKLS0tLik7S1FTkQgT1BFTlNTSCBQUklWQVRFIEtFWS0tLS0tCg==
```

Copie o resultado do base64 para dentro do ***Gitlab*** -> ***CI/CD***. Nesta etapa , estou considerando que você tenha uma ***Gitlab Runner*** disponível para seu uso. 

Caso não tenha um Runner próprio vc pode usar um Runner público, compartilhado pelo próprio Gitlab. 

![Shared Runner](https://i.ibb.co/g36tBqh/01-runner.jpg)

O que vai mudar em usar um Runner compartilhado , é forma de usa-lo dentro do ```.gitlab-ci.yml``` 

```yaml
image: docker:stable

services:
  - docker:dind

variables:
  DOCKER_HOST: tcp://docker:2375
  DOCKER_DRIVER: overlay2
``` 

### Declarar variável no Gitlab.

![Declarar Variáveis no Gitlab](https://i.ibb.co/tLv1RLf/01-gitlab.jpg)

### Rodar pipeline.

Essa é a parta mais divertida, pois agora vamos disparar um gatilho para o ```Gitlab Runner``` executar o pipeline de Restore. Sempre que houver a necessidade de fazer um ( PITR ) deve-se editar o arquivo ```.gitlab-ci.yml``` e editar as suas váriáveis. Logo após :

- git commit -am "Restaurando Backup 20200220202020"
- git push

```yaml
variables:
  #===== Dados do Backup a ser restaurado =====#
  VERSAO_POSTGRES: "release"
  ULTIMO_BACKUP: "20200220202020"
  TIMELINE_RESTORE: "2020-03-03 18:18:18"
  #============================================#
```
![Pipeline de Deploy](https://i.ibb.co/Lx0jYRw/02-gitlab.jpg)

Após o término do Pipeline, pode-se acompanhar o histórico de deploy que o projeto sofreu, no menu ***CI/CD*** -> ***PipeLines***

![Histórico Pipelines](https://i.ibb.co/Rb0rvrC/03-gitlab.jpg)

### Recebendo notificação se o Restore do Banco ocorreu com sucesso.

![Notificação via Telegram](https://i.ibb.co/HT19h66/01-telegram.jpg)

O banco ficará acessível na porta ***5433*** no servidor de Validação ***10.0.0.60***

### Arquivos que devem ser personalizados de acordo com sua infra.

- .gitlab-ci.yml
- recupera_backup.sh
- restore_command.sh
- pg_hba.conf

### Logs do processo de restauração PITR

Os logs podem ser acompanhados direto no ```Servidor de Validação```.

```bash
paulo@validacao:/home/paulo$ tail -f /var/log/postgres_restore_timeline.log

2020-03-23-00:03:43 - Iniciando processo de recovery timeline Postgres - 20200220202020
2020-03-23-00:03:48 - O serviço do PostgreSQL na porta 5433 foi parado com sucesso.
2020-03-23-00:03:54 - Copiando o Full Backup 20200220202020
2020-03-23-00:16:18 - Copiando os FILES personalizados - pg_hba.conf, postgresql.conf, recovery.conf
2020-03-23-00:16:18 - Iniciando o Cluster em - Porta 5433
2020-03-23-00:22:59 - Archives aplicados com sucesso
2020-03-23-00:22:59 - Parando Postgres para renomear recovery.conf
2020-03-23-00:23:06 - Archives foram aplicados com sucesso para restore do backup 20200220202020
2020-03-23-00:23:06 - [SUCESSO]
--------------------------------
```
