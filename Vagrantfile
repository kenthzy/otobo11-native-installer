# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.provider "virtualbox" do |vb|
    vb.memory = "4096"
    vb.cpus = 2
  end

  config.vm.define "ubuntu2404" do |ubuntu|
    ubuntu.vm.box = "bento/ubuntu-24.04"
    ubuntu.vm.hostname = "otobo-ubuntu"
    ubuntu.vm.network "private_network", type: "dhcp"
    ubuntu.vm.provision "ansible" do |ansible|
      ansible.playbook = "ansible/playbook.yml"
      ansible.groups = {
        "ubuntu" => ["ubuntu2404"],
        "debian" => []
      }
    end
  end

  config.vm.define "debian12" do |debian|
    debian.vm.box = "bento/debian-12"
    debian.vm.hostname = "otobo-debian"
    debian.vm.network "private_network", type: "dhcp"
    debian.vm.provision "ansible" do |ansible|
      ansible.playbook = "ansible/playbook.yml"
      ansible.groups = {
        "ubuntu" => [],
        "debian" => ["debian12"]
      }
    end
  end
end
