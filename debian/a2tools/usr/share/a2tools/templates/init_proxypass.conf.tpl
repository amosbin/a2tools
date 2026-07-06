<VirtualHost *:80>
    ServerName {{FQDN}}
    ErrorLog /var/log/apache-collector/{{FQDN}}_error.log
    CustomLog /var/log/apache-collector/{{FQDN}}_access.log combined
</VirtualHost>
