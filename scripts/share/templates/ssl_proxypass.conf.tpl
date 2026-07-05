<IfModule mod_ssl.c>
    <VirtualHost *:443>
        ServerName {{ACTUAL_SERVER_NAME}}
        ErrorLog /var/log/apache-collector/{{ACTUAL_SERVER_NAME}}_ssl_error.log
        CustomLog /var/log/apache-collector/{{ACTUAL_SERVER_NAME}}_ssl_access.log combined
        SSLEngine on
        SSLCertificateFile /etc/letsencrypt/live/{{CERT_DOMAIN}}/fullchain.pem
        SSLCertificateKeyFile /etc/letsencrypt/live/{{CERT_DOMAIN}}/privkey.pem
        SSLProxyEngine On
        SSLProxyVerify none
        SSLProxyCheckPeerCN off
        SSLProxyCheckPeerName off
        SSLProxyCheckPeerExpire off
        ProxyPreserveHost On
        ProxyPass / {{PROXY_PROTOCOL}}://localhost:{{PROXY_PORT}}/
        ProxyPassReverse / {{PROXY_PROTOCOL}}://localhost:{{PROXY_PORT}}/
    </VirtualHost>
</IfModule>
