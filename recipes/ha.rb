
if node[:mysql][:ebs_enabled] || node[:cloud][:provider] == "ec2"
  include_recipe "aws"
  aws = Chef::EncryptedDataBagItem.load("secrets", "aws")

  directory node[:mysql][:ebs][:mount] do
    user node[:mysql][:user]
    group node[:mysql][:group]
    mode "0755"
  end

  if node[:mysql][:ebs][:raid]
    aws_ebs_raid "data_volume_raid" do
      mount_point node[:mysql][:ebs][:mount]
      disc_count 2
      disk_size node[:mysql][:ebs][:size]
      level 10
      filesystem "ext4"
      action :auto_attach
    end
  else

    devices = Dir.glob('/dev/xvd?')
    devices = ['/dev/xvdf'] if devices.empty?
    devId = devices.sort.last[-1,1].succ

    node.set_unless[:aws][:ebs_volume][:data_volume][:device] = "/dev/xvd#{devId}"
    device_id = node[:aws][:ebs_volume][:data_volume][:device]

    aws_ebs_volume "data_volume" do
      aws_access_key aws["access_key_id"]
      aws_secret_access_key aws["access_key_secret"]
      size node[:mysql][:ebs][:size]
      device device_id.gsub('xvd', 'sd')
      action [ :create, :attach ]
    end

    ruby_block "wait-for-ebs-to-attach" do
      block do
        timeout = 0
        until File.blockdev?(device_id) || timeout == 1000
          Chef::Log.info("Device #{device_id} not ready - sleeping 2s")
          timeout += 2
          sleep 2
        end
      end
    end
  end

  mount_point = node[:mysql][:ebs][:mount]

  execute "mkfs" do
    command "mkfs.ext4 #{device_id}"
    not_if "grep -qs #{mount_point} /proc/mounts"
  end

  mount mount_point do
    device device_id
    fstype "ext4"
    options "noatime"
    action [:enable, :mount]
  end
end

if node[:mysql][:replication][:enabled]
  include_recipe "mysql"
  include_recipe "mysql::server"
  include_recipe "mysql::repl"
end
