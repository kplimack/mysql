require 'socket'

include_recipe "heartbeat"
::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

# this assumes that your hostnames match the schema:
# <location>-<class><###>[a|b] => use1d-db101a.tld & use1d-db101b.tld
# where there is a floating VIP without the [a|b] designation -> use1d-db101.tld

node[:fqdn] =~ /([a-z]{3}\d{1}[a-z-]{2}[a-z]+)(\d+)([a-b])?/i
cluster_name = $1+$2
cluster_member = $3
cluster_ip = IPSocket::getaddress(cluster_name)
cluster_netmask = "255.255.252.0"
cluster_intf = "eth0"
shortname = node[:hostname]

cluster_slaves = search(:node, "roles:mysql-ha AND chef_environment:#{node.chef_environment} AND hostname:#{cluster_name}* AND NOT hostname:#{shortname}")


Chef::Log.info("Checking HB Authkeys")
if node['heartbeat']['config']['authkeys'].nil?
  genkey = true
  Chef::Log.info("No Authkey Found")
  Chef::Log.info("Missing authkeys, searching for other nodes that might have one")
  # This node doesn't have a key, but maybe the other one(s) do
  cluster_slaves.each do |js|
    Chef::Log.info("checking for key on #{node['fqdn']}")
    begin
      unless js['heartbeat']['config']['authkeys'].nil?
        Chef::Log.info("Found a key to use on #{js['fqdn']}")
        node.set['heartbeat']['config']['authkeys'] = js['heartbeat']['config']['authkeys']
        node.save
        genkey = false
        break
      end
      rescue
    end
    if genkey
      Chef::Log.info("No keys found on other node, generating secure key")
      node.set_unless['heartbeat']['config']['authkeys'] = secure_password
      node.save
    end
  end
end

ha_resources = Array.new
ha_resources.push("IPaddr::#{cluster_ip}/#{cluster_netmask}/#{cluster_intf}")
begin
    node[:heartbeat][:ha_resources].each do |k,v|
        ha_resources.push(v)
      end
    rescue NoMethodError
  end

heartbeat "mysql-heartbeat" do
  auto_failback false
  autojoin "none"
  deadtime 180
  initdead 180
  logfacility "local0"
  authkeys node[:heartbeat][:config][:authkeys]
  warntime 15
  search "chef_environment:#{node.chef_environment} AND roles:mysql-ha AND hostname:#{cluster_name}*"
  interface cluster_intf
  interface_partner_ip cluster_slaves.first[:ipaddress]
  mode "ucast"
  resource_groups ha_resources
end

puts "Settings up replication with: " + cluster_slaves.inspect

ruby_block "create-replication-users" do
  block do
    cluster_slaves.each do |slave|
      puts "create-replication-users: #{slave[:fqdn]}"
      %x{mysql -u root -p#{node[:mysql][:server_root_password]} -e "GRANT REPLICATION SLAVE ON *.* to 'repl'@'#{slave[:ipaddress]}' IDENTIFIED BY '#{node[:mysql][:server_repl_password]}';"}
    end
  end
  action :create
end

# now we set up master stuff

directory "#{node[:mysql][:data_dir]}/var/lib/mysql" do
  owner node[:mysql][:user]
  group node[:mysql][:group]
  recursive true
end

node[:ipaddress] =~ /(\d{1,3})$/
node.set_unless[:mysql][:replication][:serverid] = $1
node.save

template "/etc/mysql/conf.d/repl.cnf" do
  source "repl.cnf.rb"
  owner node[:mysql][:user]
  group node[:mysql][:group]
  mode "0700"
  notifies :restart, "mysql_service[default]", :immediately
end

ruby_block "master-log" do
  block do
    logs = %x[mysql -u root -p#{node[:mysql][:server_root_password]} -e "show master status;" | grep mysql].strip.split
    puts "Logs[0] = #{logs[0]}"
    puts "Logs[1] = #{logs[1]}"
    node.set[:mysql][:server][:log_file] = logs[0]
    node.set[:mysql][:server][:log_pos] = logs[1]
    node.save
  end
  action :create
end

unless tagged?("replication-configured")
  ruby_block "import-master-log" do
    block do
      master_log_file = cluster_slaves.first[:mysql][:server][:logfile]
      master_log_pos = cluster_slaves.first[:mysql][:server][:log_pos]
      puts "Configuring Replication: CHANGE MASTER TO #{cluster_slaves.first[:ipaddress]}"
      %x{mysql -u root -p#{node[:mysql][:server_root_password]} -e "CHANGE MASTER TO master_host='#{cluster_slaves.first[:ipaddress]}', master_port=3306, master_user='repl', master_password='#{cluster_slaves.first[:mysql][:server_repl_password]}', master_log_file='#{master_log_file}', master_log_pos=#{master_log_pos};"}
      %x{mysql -u root -p#{node[:mysql][:server_root_password]} -e "START SLAVE;"}
    end
    action :create
  end
  tag("replication-configured")
end
