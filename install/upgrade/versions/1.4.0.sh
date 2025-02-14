#!/bin/sh

# Hestia Control Panel upgrade script for target version 1.4.0

#######################################################################################
#######                      Place additional commands below.                   #######
#######################################################################################

# Add support for nginx FastCGI cache (standalone)
if [ -e "/etc/nginx/nginx.conf" ]; then
    check=$(cat /etc/nginx/nginx.conf | grep 'fastcgi_cache_path');
    if [ -z "$check" ]; then 
        echo "[ * ] Enabling nginx FastCGI cache support..."
        sed  -i 's/# Cache bypass/# FastCGI cache\n    fastcgi_cache_path \/var\/cache\/nginx\/micro levels=1:2 keys_zone=microcache:10m max_size=1024m inactive=30m;\n    fastcgi_cache_key \"$scheme$request_method$host$request_uri\";\n    fastcgi_cache_methods GET HEAD;\n    fastcgi_cache_use_stale updating error timeout invalid_header http_500 http_503;\n    fastcgi_ignore_headers Cache-Control Expires Set-Cookie;\n    add_header X-FastCGI-Cache \$upstream_cache_status;\n\n    # Cache bypass/g' /etc/nginx/nginx.conf
    fi
fi

# Populating HELO/SMTP Banner for existing IPs
if [ "$MAIL_SYSTEM" == "exim4" ]; then

    # Check if we've already done this upgrade before proceeding
    if ! grep -q ^smtp_active_hostname  /etc/exim4/exim4.conf.template; then

        source $HESTIA/func/ip.sh

        echo "[ * ] Populating HELO/SMTP Banner value for existing IP addresses..."
        > /etc/exim4/mailhelo.conf

        for ip in $($BIN/v-list-sys-ips plain | cut -f1); do
            helo=$(is_ip_rdns_valid $ip)

            if [ ! -z "$helo" ]; then
                $BIN/v-change-sys-ip-helo $ip $helo
            fi
        done

        # Update exim configuration
        echo "[ * ] Updating exim4 configuration..."

        # Add new smtp_active_hostname variable to exim config
        sed -i '/^smtp_banner = \$smtp_active_hostname$/a smtp_active_hostname = ${if exists {\/etc\/exim4\/mailhelo.conf}{${lookup{$interface_address}lsearch{\/etc\/exim4\/mailhelo.conf}{$value}{$primary_hostname}}}{$primary_hostname}}' /etc/exim4/exim4.conf.template

        # Lookup HELO address by sending ip instead of sending domain
        sed -i 's/helo_data = \${if exists {\/etc\/exim4\/mailhelo.conf}{${lookup{\$sender_address_domain}lsearch\*{\/etc\/exim4\/mailhelo.conf}{\$value}{\$primary_hostname}}}{\$primary_hostname}}/helo_data = ${if exists {\/etc\/exim4\/mailhelo.conf}{${lookup{$sending_ip_address}lsearch{\/etc\/exim4\/mailhelo.conf}{$value}{$primary_hostname}}}{$primary_hostname}}/' /etc/exim4/exim4.conf.template
    fi
fi

# Upgrading Mail System
if [ "$MAIL_SYSTEM" == "exim4" ]; then
    if ! grep -q "send_via_smtp_relay" /etc/exim4/exim4.conf.template; then

        echo '[ * ] Enabling SMTP relay support...'
        if grep -q "driver = plaintext" /etc/exim4/exim4.conf.template; then
            disable_smtp_relay=true
            echo '[ ! ] ERROR: Manual intervention required to enable SMTP Relay:'
            echo ''
            echo '      Exim only supports one plaintext authenticator.'
            echo '      If you want to use the Hestia smtp relay feature,'
            echo '      please review the /etc/exim4/exim4.conf.template'
            echo '      file and resolve any conflicts.'
        else
            disable_smtp_relay=false
        fi

        # Add smtp relay macros to exim config
        insert='SMTP_RELAY_FILE = ${if exists{/etc/exim4/domains/${sender_address_domain}/smtp_relay.conf}{/etc/exim4/domains/$sender_address_domain/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}\n\SMTP_RELAY_HOST=${lookup{host}lsearch{SMTP_RELAY_FILE}}\n\SMTP_RELAY_PORT=${lookup{port}lsearch{SMTP_RELAY_FILE}}\n\SMTP_RELAY_USER=${lookup{user}lsearch{SMTP_RELAY_FILE}}\n\SMTP_RELAY_PASS=${lookup{pass}lsearch{SMTP_RELAY_FILE}}\n'

        if [ "$disable_smtp_relay" = true ]; then
            insert=$(sed 's/^/#/g; s/\\n/\\n#/g; s/.$//' <<< $insert)
        fi

        line=$(expr $(sed -n '/ACL CONFIGURATION/=' /etc/exim4/exim4.conf.template) - 1)
        sed -i "${line}i $insert" /etc/exim4/exim4.conf.template

        # Add smtp relay authenticator
        insert='smtp_relay_login:\n\  driver = plaintext\n\  public_name = LOGIN\n\  hide client_send = : SMTP_RELAY_USER : SMTP_RELAY_PASS\n'

        if [ "$disable_smtp_relay" = true ]; then
            insert=$(sed 's/^/#/g; s/\\n/\\n#/g; s/.$//' <<< $insert)
        fi

        line=$(expr $(sed -n '/begin authenticators/=' /etc/exim4/exim4.conf.template) + 2)
        sed -i "${line}i $insert" /etc/exim4/exim4.conf.template

        # Add smtp relay router
        insert='send_via_smtp_relay:\n\  driver = manualroute\n\  address_data = SMTP_RELAY_HOST:SMTP_RELAY_PORT\n\  domains = !+local_domains\n\  require_files = SMTP_RELAY_FILE\n\  transport = smtp_relay_smtp\n\  route_list = * ${extract{1}{:}{$address_data}}::${extract{2}{:}{$address_data}}\n\  no_more\n\  no_verify\n'

        if [ "$disable_smtp_relay" = true ]; then
            insert=$(sed 's/^/#/g; s/\\n/\\n#/g; s/.$//' <<< $insert)
        fi

        line=$(expr $(sed -n '/begin routers/=' /etc/exim4/exim4.conf.template) + 2)
        sed -i "${line}i $insert" /etc/exim4/exim4.conf.template

        # Add smtp relay transport
        insert='smtp_relay_smtp:\n\  driver = smtp\n\  hosts_require_auth = $host_address\n\  hosts_require_tls = $host_address\n'

        if [ "$disable_smtp_relay" = true ]; then
            insert=$(sed 's/^/#/g; s/\\n/\\n#/g; s/.$//' <<< $insert)
        fi

        line=$(expr $(sed -n '/begin transports/=' /etc/exim4/exim4.conf.template) + 2)
        sed -i "${line}i $insert" /etc/exim4/exim4.conf.template
    fi
fi

# Fix PostgreSQL repo
if [ -f /etc/apt/sources.list.d/postgresql.list ]; then
    echo "[ * ] Updating PostgreSQL repository..."
    sed -i 's|deb https://apt.postgresql.org/pub/repos/apt/|deb [arch=amd64] https://apt.postgresql.org/pub/repos/apt/|g' /etc/apt/sources.list.d/postgresql.list
fi

# Remove API file if API is set to "no"
if [ "$API" = "no" ]; then
    if [ -f "$HESTIA/web/api/index.php" ]; then
        echo "[ * ] Disabling API access..."
        $HESTIA/bin/v-change-sys-api remove
    fi
fi

# Back up users existing configuration data to $HESTIA/conf/defaults/hestia.conf
if [ ! -f "$HESTIA/conf/defaults/hestia.conf" ]; then
    echo "[ * ] Creating known good configuration data for system recovery..."
    if [ ! -d "$HESTIA/conf/defaults/" ]; then
        mkdir -p "$HESTIA/conf/defaults/"
    fi
    cp -f $HESTIA/conf/hestia.conf $HESTIA/conf/defaults/hestia.conf
fi

if [ -f "/usr/lib/networkd-dispatcher/routable.d/50-ifup-hooks" ]; then
    echo "[ * ] Fix potenial issue with multiple network adapters and netplan..."
    rm "/usr/lib/networkd-dispatcher/routable.d/50-ifup-hooks"
    $BIN/v-update-firewall
fi

# Consolidate nginx (standalone) templates used by active websites
if [ "$WEB_SYSTEM" = "nginx" ]; then
    echo "[ * ] Consolidating nginx templates for Drupal & CodeIgniter..."
    sed -i "s|TPL='drupal6'|TPL='drupal'|g" $HESTIA/data/users/*/web.conf
    sed -i "s|TPL='drupal7'|TPL='drupal'|g" $HESTIA/data/users/*/web.conf
    sed -i "s|TPL='drupal8'|TPL='drupal'|g" $HESTIA/data/users/*/web.conf
    sed -i "s|TPL='codeigniter2'|TPL='codeigniter'|g" $HESTIA/data/users/*/web.conf
    sed -i "s|TPL='codeigniter3'|TPL='codeigniter'|g" $HESTIA/data/users/*/web.conf
fi

# Remove outdated nginx templates
echo "[ * ] Removing outdated nginx templates..."
rm -rf $HESTIA/data/templates/web/nginx/php-fpm/drupal6.*tpl
rm -rf $HESTIA/data/templates/web/nginx/php-fpm/drupal7.*tpl
rm -rf $HESTIA/data/templates/web/nginx/php-fpm/drupal8.*tpl
rm -rf $HESTIA/data/templates/web/nginx/php-fpm/codeigniter2.*tpl
rm -rf $HESTIA/data/templates/web/nginx/php-fpm/codeigniter3.*tpl
