#!/bin/bash

# Constantes gerais
SCRIPT_CONFIG_BKP_DIR="/root/script_config_bkp"

# Constantes de certificado
CERT_DIR="/etc/nginx/certificado"
PRIV_KEY="cert.key"
PUB_KEY="cert.crt"
DHPARAM="dhparam.pem"

# Constantes do NGINX
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"

# Constantes do MariaDB
MARIADB_SOURCES_FILE="/etc/apt/sources.list.d/mariadb.sources"

# Variáveis globais
verbose=false

## Funções auxiliares

# Para poder dar echo com cor :D
echo_color () {
  local texto="$1"
  local cor="$2"
  local RED='\033[0;31m'
  local GREEN='\033[0;32m'
  local YELLOW='\033[0;33m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  case "$cor" in
    red) echo -e "${RED}${texto}${NC}" ;;
    green) echo -e "${GREEN}${texto}${NC}" ;;
	yellow) echo -e "${YELLOW}${texto}${NC}" ;;
	blue) echo -e "${BLUE}${texto}${NC}" ;;
    *) echo "$texto" ;;
  esac
}

# Função para executar comando em 2° plano, o output aparece se o comando não foi sucedido
executar () {
	command="$1"

	if [ $verbose = true ]; then
		echo_color "Executando \"$command\"..." blue
		eval "$command"
		result=$?
	else
		output=$( (eval "$command") 2>&1 )
		result=$?
		[ $result -ne 0 ] && echo_color "$output" yellow
	fi
	
	return $result
}

# Para atualizar pacotes :p
atualizar_pacotes () {

	echo "Atualizando pacotes..."
	executar "apt update"
	if [ $? -ne 0 ]; then
		echo_color "Pacotes não foram atualizados" red
		exit 1
	fi
}

# Libera porta para um serviço específico
liberar_porta () {
	service_name="$1"
	service_port="$2"

	echo "Liberando porta $service_port para $service_name..."

	# Busca o nome do serviço que está rodando na porta do argumento
	process_name=$( eval "lsof -i :$service_port | tail -n +2 | awk '{ print $1; exit }'" 2>&1 )


	if [ -n "$process_name" ]; then
		executar "killall $process_name"
		if [ $? -ne 0 ]; then
			echo_color "$service_port não liberada" red
			exit 1
		fi
	fi

	return 0
}

# Faz bkp do arquivo se existir
bkp_file () {
	file_name="$1"

	if [ -f $file_name ]; then
		echo "Fazendo backup do arquivo $file_name..."
		executar "mv \"$file_name\" \"$SCRIPT_CONFIG_BKP_DIR/bkp_$(basename "$file_name")\""
	fi

	return $?
}

# Faz bkp de um diretório se existir
bkp_dir () {
	dir_name="$1"

	if [ -d $dir_name ]; then
		echo "Fazendo backup do diretório $dir_name..."
		executar "mv -r \"$dir_name\" \"$SCRIPT_CONFIG_BKP_DIR/bkp_$(basename "$dir_name")\""
	fi

	return $?
}

# Configurar SSH
configurar_ssh(){
	echo "Configurando ssh..."

	# Liberando porta
	liberar_porta ssh 22

	executar "systemctl --no-pager status ssh"
	if [ $? -ne 0 ]; then
		echo "Instalando ssh... "
		executar "apt install openssh-server -y"
	fi

	ssh_is_active=$( (eval "systemctl --no-pager is-active ssh") 2>&1 )
	if [ "$ssh_is_active" != "active" ]; then
		echo "Ativando ssh... "
		executar "systemctl --no-pager start ssh"
	fi

	ssh_is_enabled=$( (eval "systemctl --no-pager is-enabled ssh") 2>&1 )
	if [ "$ssh_is_enabled" != "enabled" ]; then
		echo "Habilitando ssh... "
		executar "systemctl --no-pager enable ssh"
	fi

	echo_color "SSH: OK" green
}

# Configurar DNS
configurar_dns(){
	echo "Configurando dns..."

	dns_ips=("1.1.1.1" "8.8.8.8")
	dns_names=("Cloudfare" "Google")
	resolv_file="/etc/resolv.conf"

	for i in "${!dns_ips[@]}"; do
		dns="${dns_ips[$i]}"
		name="${dns_names[$i]}"
		text_index=$((i+1))

		echo "$text_index - $name ($dns)... "
		
		if ! grep -Fxq "nameserver $dns" "$resolv_file"; then
			executar "echo \"nameserver $dns\" >> \"$resolv_file\""
		fi
	done

	echo_color "DNS: OK" green
}

# Validar se certificado está OK
validar_certificado () {

	# Validar integridade do certificado
	executar "openssl x509 -in $CERT_DIR/$PUB_KEY -noout -text"
	if [ $? -ne 0 ]; then return 1; fi

	## Validar hash com chaves do certificado

	# Pegando hash com chave pública
	pubkey_hash=$( eval "openssl x509 -noout -modulus -in $CERT_DIR/$PUB_KEY | openssl md5" 2>&1 )
	if [ $? -ne 0 ]; then return 1; fi

	# Pegando hash com chave privada
	privkey_hash=$( eval "openssl rsa -noout -modulus -in $CERT_DIR/$PRIV_KEY | openssl md5" 2>&1 )
	if [ $? -ne 0 ]; then return 1; fi

	# Comparando hashes
	if [ "$pubkey_hash" != "$privkey_hash" ]; then return 1; fi

	# Verificando diffie-heiman
	executar "openssl dhparam -in $CERT_DIR/$DHPARAM -check"
	return $?
}

# Cria certificado
criar_certificado () {

	# Criando diretório para os arquivos do certificado ssl
	executar "mkdir -p $CERT_DIR"

	# Guardando bkp dos arquivos
	bkp_file "$CERT_DIR/$PRIV_KEY"
	bkp_file "$CERT_DIR/$PUB_KEY"
	bkp_file "$CERT_DIR/$DHPARAM"

	executar "openssl req -x509 -nodes -days 4380 -newkey rsa:4096 -keyout '$CERT_DIR/$PRIV_KEY' -out $CERT_DIR/$PUB_KEY -subj '/C=BR/ST='\"netevolution\"'/L=Chapeco/O=Dis/CN=netevolution.ixcsoft.com.br'"

	executar "openssl dhparam -out '$CERT_DIR/$DHPARAM' 2048"
	
	return 0
}

# Configurar NGINX
configurar_nginx() {
	echo "Configurando nginx..."

	liberar_porta nginx 80

	echo "Verificando instalação do nginx..."
	executar "systemctl --no-pager status nginx"
	nginx_status_exit_code=$?
	
	echo "Testando configurações do nginx..."
	executar "nginx -t"
	nginx_config_test_exit_code=$?

	# Se não estiver instalado ou estier mal configurado, tudo sobre nginx será reinstalado e configurado
	if [ $nginx_status_exit_code -ne 0 ] || [ $nginx_config_test_exit_code -ne 0 ]; then
		echo "Instalando nginx do zero... "
		executar "apt purge nginx nginx-common nginx-core -y"
		executar "rm -rf /etc/nginx"
		executar "apt install nginx -y"
		if [ $? -ne 0 ]; then
			echo_color "nginx não instalado" red
			exit 1
		fi
	fi

	# Verificando atividade do nginx
	nginx_is_active=$( (eval "systemctl --no-pager is-active nginx") 2>&1 )
	if [ "$nginx_is_active" != "active" ]; then
		echo "Ativando... "
		executar "systemctl --no-pager start ssh"
		if [ $? -ne 0 ]; then
			echo_color "nginx não ativado" red
			exit 1
		fi
	fi

	# Verificando se nginx está habilitado
	nginx_is_enabled=$( (eval "systemctl --no-pager is-enabled nginx") 2>&1 )
	if [ "$nginx_is_enabled" != "enabled" ]; then
		echo "Habilitando... "
		executar "systemctl --no-pager enable nginx"
		if [ $? -ne 0 ]; then
			echo_color "nginx não habilitado" red
			exit 1
		fi
	fi

	echo "Validando certificado ssl..."
	validar_certificado
	if [ $? -ne 0 ]; then
		echo "Certificado inválido ou inexistente! Criando certificado ssl..."
		criar_certificado
		validar_certificado
		if [ $? -ne 0 ]; then
			echo_color "Certificado ssl criado é inválido!" red
			exit 1
		fi
	fi

	echo "Configurando sites-enabled..."

	# Guarda bkp do arqivo de configuração padrão do NGINX
	bkp_file "$NGINX_SITES_ENABLED/default"
	if [ $? -ne 0 ]; then
		echo_color "Configuração do NGINX não finalizada: arquivo de configuração padrão do nginx não pôde ser movido..." red
		exit 1
	fi
	# Inserindo arquivo http
	bkp_file "$NGINX_SITES_ENABLED/http"
	executar "echo 'server {
		listen 80 default_server;
		listen [::]:80 default_server;

		location / {
			return 301 https://\$host\$request_uri; # Redireciona para a mesma página, mas https. Retorna 301 que é o código http de redirecionado
		}
	}' > $NGINX_SITES_ENABLED/http"

	# Inserindo arquivo https
	bkp_file "$NGINX_SITES_ENABLED/https"
	executar "echo 'server {
		listen 443 ssl;
		listen [::]:443 ssl;
		include sites-enabled/*.conf;
		error_page 405 =200 ;

		root /var/www/html;
		server_name _;
		index index.php index.html;

		location / {
			try_files \$uri \$uri/ /index.php?\$args;
		}

		location ~ \.php$ {
			include /etc/nginx/fastcgi_params;
			include snippets/fastcgi-php.conf;
					fastcgi_pass unix:/run/php/php-fpm.sock;
					fastcgi_read_timeout 3600;
		}
	}' > $NGINX_SITES_ENABLED/https"

	# Inserindo arquivo para carregar o certificado
	bkp_file "$NGINX_SITES_ENABLED/ssl.conf"
	executar "echo \"
		ssl_certificate $CERT_DIR/$PUB_KEY;
		ssl_certificate_key $CERT_DIR/$PRIV_KEY;
		ssl_dhparam $CERT_DIR/$DHPARAM;
	\" > $NGINX_SITES_ENABLED/ssl.conf"
	
	# Recarregar configurações do nginx
	executar "systemctl --no-pager reload nginx"

	# Testar configurações
	executar "nginx -t"
	if [ $? -ne 0 ]; then
		echo_color "NGINX não configurado corretamente" red
		exit 1
	fi

	# Criar diretório root da web
	executar "mkdir -p /var/www/html"

	# Colocando página home do net evolution
	executar "echo '<!DOCTYPE html>
	<html lang="en">
	<head>
		<meta charset="UTF-8">
		<title>Hello World</title>
		<link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@700\&display=swap" rel="stylesheet">
		<style>
			body {
				background-color: #041656;
				color: #0AE782;
				font-family: "Montserrat", sans-serif;
				font-weight: 700;
				font-size: 4em;
				display: flex;
				align-items: center;
				justify-content: center;
				height: 100vh;
				margin: 0;
			}
		</style>
	</head>
	<body>
		Eu tô no NET {evolution}! 🚀
	</body>
	</html>' > /var/www/html/index.php"

	executar "chown -R www-data:www-data /var/www/html"
	executar "chmod -R 755 /var/www/html"

	echo_color "NGINX: OK" green
}

# Configurar PHP
configurar_php () {
	# echo_color "Configuração do PHP ainda não implementada! " blue
	service_name="php8.2-fpm"
	echo "Configurando $service_name..."

	echo "Verificando instalação d $service_name..."
	executar "systemctl --no-pager status $service_name"
	php_status_exit_code=$?

	# Se não estiver instalado, tudo sobre php8.2-fpm será reinstalado e configurado
	if [ $php_status_exit_code -ne 0 ]; then
		echo "Instalando $service_name... "
		executar "apt purge $service_name php8.2-common php8.2-cli -y"
		executar "rm -rf /etc/php/8.2/fpm"
		executar "apt install $service_name -y"
		if [ $? -ne 0 ]; then
			echo_color "$service_name não instalado" red
			exit 1
		fi
	fi

	# Verificando atividade do php
	php_is_active=$( (eval "systemctl --no-pager is-active $service_name") 2>&1 )
	if [ "$php_is_active" != "active" ]; then
		echo "Ativando $service_name... "
		executar "systemctl --no-pager start $service_name"
		if [ $? -ne 0 ]; then
			echo_color "$service_name não ativado" red
			exit 1
		fi
	fi

	# Verificando se php está habilitado
	nginx_is_enabled=$( (eval "systemctl --no-pager is-enabled $service_name") 2>&1 )
	if [ "$nginx_is_enabled" != "enabled" ]; then
		echo "Habilitando $service_name... "
		executar "systemctl --no-pager enable $service_name"
		if [ $? -ne 0 ]; then
			echo_color "$service_name não habilitado" red
			exit 1
		fi
	fi

	echo_color "$service_name: OK" green

}

configurar_monitoramento_php_nginx () {
	echo "Configurando monitoramento de processos PHP..."

	echo "Configurando monitoramento do PHP-FPM (pool www)..."
	www_conf_file="/etc/php/8.2/fpm/pool.d/www.conf"
	bkp_file "$www_conf_file"
	executar "cat <<'EOF' > $www_conf_file
[www]

user = www-data
group = www-data
listen = /run/php/php-fpm.sock

listen.owner = www-data
listen.group = www-data

pm = dynamic
pm.max_children = 200
pm.start_servers = 20
pm.min_spare_servers = 10
pm.max_spare_servers = 20
pm.max_requests = 1000
pm.status_path = /status
ping.path = /ping
ping.response = OK
chdir = /
EOF"
	
	# Criando virtual host no NGINX para monitoramento local de status do PHP e NGINX
	echo "Criando virtual host no NGINX..."
	bkp_file "$NGINX_SITES_ENABLED/status_proc"
	executar "cat <<'EOF' > $NGINX_SITES_ENABLED/status_proc
server {
	listen 8087;
	listen [::]:8087;
	allow 127.0.0.1;
	allow ::1;
	deny all;

	location ~ ^/(status|ping)$ {
		chunked_transfer_encoding off;
		include fastcgi_params;
		fastcgi_pass unix:/run/php/php-fpm.sock;
		fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
	}

	location /basic_status {
		stub_status;
	}
}
EOF"

	executar "systemctl reload nginx"
	executar "nginx -t"
	if [ $? -ne 0 ]; then
		echo_color "NGINX & PHP: Configurações de processos PHP não corretas" red
		exit 1
	else
		echo_color "NGINX & PHP: OK" green
	fi
}

configurar_mariadb () {
	echo_color "Configurando mariadb..."
	db_user="netevolution"
	db_pass="netevolution"
	db_host="%"
	# Procurar o primeiro arquivo .sql no diretório atual
	db_dump_file=$(find . -maxdepth 1 -type f -name "*.sql" | head -n 1)
	# Procura pelo nome do banco de dados no arquivo .sql, se encontrar!
	db_dump_name=$(grep -i '^-- Host: .* Database:' "$db_dump_file" | awk -F'Database: ' '{print $2}' | awk '{print $1}')

	echo "Verificando instalação de mariadb..."
	executar "systemctl --no-pager status mariadb"
	# Se não conseguir puxar status, instala o mariadb
	if [ $? -ne 0 ]; then
		echo "Preparando instalação..."
		# Prepara o arquivo sources do mariadb
		executar "apt install apt-transport-https curl -y"
		executar "mkdir -p /etc/apt/keyrings"
		executar "curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'"
		executar "echo \"
			# MariaDB 11.4 repository list - created 2025-08-02 13:50 UTC
			# https://mariadb.org/download/
			X-Repolib-Name: MariaDB
			Types: deb
			# deb.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits>
			# URIs: https://deb.mariadb.org/11.4/debian
			URIs: https://mirror.rackspace.com/mariadb/repo/11.4/debian
			Suites: bookworm
			Components: main
			Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
		\" > $MARIADB_SOURCES_FILE"

		# Finaliza o script se deu erro ao preparar arquivo source list
		if [ $? -ne 0 ]; then
			echo_color "MARIADB: Erro a configurar arquivo para instalação" red
			exit 1
		fi

		# Instala o mariadb-server
		atualizar_pacotes
		echo "Instalando mariadb-server..."
		executar "apt install mariadb-server -y"

		# Finalizada o script se a instalação não deu certo
		if [ $? -ne 0 ]; then
			echo_color "MARIADB: Erro ao instalar mariadb-server" red
			exit 1
		fi
	fi

	echo "Criando banco de dados..."
	# Ignora a restauração de dados se não achou um arquivo .sql no dir atual 
	if [ -z "$db_dump_file" ]; then
		echo_color "Nenhum arquivo .sql encontrado no diretório atual" yellow
		echo "Ignorando restauração de banco de dados..."
	else
		# Ignora restauração de dados se não achou o nome do BD no arquivo .sql
		if [ -z "$db_dump_name" ]; then
			echo_color "Nome do banco de dados não identificado em $db_dump_file. Nome encontrado: '$db_dump_name'" yellow
			echo_color "Ignorando restauração de dados..." yellow
		else
			# Inicia restauração de dados
			echo "Restaurando banco de dados..."
			executar "mariadb -e \"CREATE DATABASE IF NOT EXISTS $db_dump_name\""
			executar "mariadb \"$db_dump_name\" < \"$db_dump_file\""

			# Define o nome do banco como usuário se deu certo
			if [ $? -ne 0 ]; then
				echo_color "MARIADB: Restauração não realizada" red
			else
				db_user="$db_dump_name"
			fi
		fi
	fi

	# Criar usuário BD
	echo "Criando usuário BD"
	executar "mariadb -e \"CREATE USER IF NOT EXISTS '$db_user'@'$db_host' IDENTIFIED BY '$db_pass'\""

	# Se conseguiu criar usuário BD, criar permissões
	if [ $? -eq 0 ]; then
		executar "mariadb -e \"GRANT ALL PRIVILEGES ON $db_dump_name.* TO '$db_user'@'$db_host' WITH GRANT OPTION\""

		# Mensagem de erro se não foi possível criar permissões
		if [ $? -ne 0 ]; then
			echo_color "MARIADB: Erro ao criar permissões de usuário BD" red
		else
			echo_color "Usuário: $db_user\nSenha: $db_pass\nHost: $db_host" yellow
		fi
	else
		echo_color "MARIADB: Erro ao criar usuário BD" red
	fi
	
	echo_color "MARIADB: OK" green
	
}

main (){
	# Parse de argumentos
	while getopts "v" opt; do
		case "$opt" in
			v)
				verbose=true
				;;
		esac
	done

	# Se não for root, nem começa o script
	if [ "$EUID" -ne 0 ]; then
		echo_color "Permissão negada, execute como root para continuar" red
		echo "Dica: execute 'su -' (ou 'sudo su -' para outras distribuições ) para acessar como root"
		exit 1
	fi

	# Cria diretório de bkp
	executar "mkdir -p $SCRIPT_CONFIG_BKP_DIR"

	atualizar_pacotes
	configurar_ssh
	configurar_dns
	configurar_nginx
	configurar_php
	configurar_monitoramento_php_nginx
	configurar_mariadb
}

main "$@"
