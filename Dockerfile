FROM wordpress:6.1.1-php8.1-apache

ENV APACHE_SERVER_NAME="localhost" \
    APACHE_RUN_USER="infwp" \
    APACHE_RUN_GROUP="infwp" \
    APACHE_PORT_HTTP="8080" \
    APACHE_PORT_HTTPS="8443" \
    APACHE_LOG_DIR="/var/log/apache2"

RUN groupadd -g 2000 ${APACHE_RUN_GROUP} && \
    useradd -s /bin/bash -u 2000 -g ${APACHE_RUN_GROUP} ${APACHE_RUN_USER};

RUN sed -i 's/Listen 80/Listen ${APACHE_PORT_HTTP}/g' /etc/apache2/ports.conf; \
    sed -i 's/Listen 443/Listen ${APACHE_PORT_HTTPS}/g' /etc/apache2/ports.conf; \
    sed -i 's/:80/:${APACHE_PORT_HTTP}/g' /etc/apache2/sites-enabled/000-default.conf; \
    sed -i 's/#ServerName www.example.com/ServerName ${APACHE_SERVER_NAME}/g' /etc/apache2/sites-enabled/000-default.conf;

USER ${APACHE_RUN_USER}

EXPOSE ${APACHE_PORT_HTTP}

CMD ["apache2-foreground"]
