<IfModule mod_ssl.c>
    <VirtualHost *:443>
        ServerName {{FQDN}}
        ServerAlias *.{{FQDN}}
        DocumentRoot /var/www/{{FQDN}}/public_html
        ErrorLog /var/log/apache-collector/{{FQDN}}_ssl_error.log
        CustomLog /var/log/apache-collector/{{FQDN}}_ssl_access.log vhost_combined
        SSLEngine on
        SSLCertificateFile /etc/letsencrypt/live/{{FQDN}}/fullchain.pem
        SSLCertificateKeyFile /etc/letsencrypt/live/{{FQDN}}/privkey.pem
    </VirtualHost>
</IfModule>
