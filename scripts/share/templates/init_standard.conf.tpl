<VirtualHost *:80>
    ServerName {{FQDN}}
    ServerAlias *.{{FQDN}}
    DocumentRoot /var/www/{{FQDN}}/public_html
    ErrorLog /var/log/apache-collector/{{FQDN}}_error.log
    CustomLog /var/log/apache-collector/{{FQDN}}_access.log combined
</VirtualHost>
