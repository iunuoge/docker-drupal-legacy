#!/bin/bash

# Run Confd to make config files
/usr/local/bin/confd -onetime -backend env

# Export all env vars containing "_" to a file for use with cron jobs
printenv | grep \_ | sed 's/^\(.*\)$/export \1/g' | sed 's/=/=\"/' | sed 's/$/"/g' > /root/project_env.sh
chmod +x /root/project_env.sh

# Add gitlab to hosts file
grep -q -F "$GIT_HOSTS" /etc/hosts  || echo $GIT_HOSTS >> /etc/hosts

# Add cron jobs
if [[ -n "$GIT_REPO" ]] ; then
  sed -i "/drush/s/^\w*/$(echo $GIT_REPO | md5sum | grep -P '[0-5][0-9]' -o | head -1)/" /root/crons.conf
fi
if [[ ! -n "$PRODUCTION" || $PRODUCTION != "true" ]] ; then
  sed -i "/git pull/s/[0-9]\+/5/" /root/crons.conf
fi

# Clone repo to container
git clone --depth=1 -b $GIT_BRANCH $GIT_REPO /var/www/site/

# Symlink files folder
mkdir -p /mnt/sites-files/public
mkdir -p /mnt/sites-files/private
mkdir -p $APACHE_DOCROOT/sites/default
cd $APACHE_DOCROOT/sites/default && ln -sf /mnt/sites-files/public files
cd /var/www/site/ && ln -sf /mnt/sites-files/private private

# Set DRUPAL_VERSION
echo $(/usr/local/src/drush/drush --root=$APACHE_DOCROOT status | grep "Drupal version" | awk '{ print substr ($(NF), 0, 2) }') > /root/drupal-version.txt

# Install appropriate apache config and restart apache
if [[ -n "$WWW" &&  $WWW = "true" ]] ; then
  cp /root/wwwsite.conf /etc/apache2/sites-enabled/000-default.conf
fi

# Import starter.sql, if needed
/root/mysqlimport.sh

# Create Drupal settings, if they don't exist as a symlink
ln -s $APACHE_DOCROOT /root/apache_docroot
/root/drupal-settings.sh

# Load configs
/root/load-configs.sh

# Hide Drupal errors in production sites
if [[ -n "$PRODUCTION" && $PRODUCTION = "true" ]] ; then
  grep -q -F "\$conf['error_level'] = 0;" $APACHE_DOCROOT/sites/default/settings.php  || echo "\$conf['error_level'] = 0;" >> $APACHE_DOCROOT/sites/default/settings.php
else
  grep -q -F 'Header set X-Robots-Tag "noindex, nofollow"' /etc/apache2/sites-enabled/000-default.conf || sed -i 's/.*\/VirtualHost.*/\tHeader set X-Robots-Tag \"noindex, nofollow\"\n\n&/' /etc/apache2/sites-enabled/000-default.conf
fi

# set permissions on php log
chmod 640 /var/log/php5-fpm.log
chown www-data:www-data /var/log/php5-fpm.log

crontab /root/crons.conf
/usr/bin/supervisorctl restart apache2
