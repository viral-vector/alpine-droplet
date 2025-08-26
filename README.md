# Digital Ocean Alpine Linux Image Generator

![Build Status](https://github.com/benpye/alpine-droplet/actions/workflows/build.yml/badge.svg?branch=master)

This is a tool to generate an Alpine Linux custom image for Digital Ocean. This ensures that the droplet will correctly configure networking and SSH on first boot using Digital Ocean's metadata service. To use this tool make sure you have `qemu-nbd`, `qemu-img`, `bzip2` and `e2fsprogs` installed. This will not work under the Windows Subsystem for Linux (WSL) as it mounts the image during generation.

Once these prerequisites are installed run:

```bash
# ./build-image.sh
```

Note: Need root permission.

This will produce `alpine-virt-image-{timestamp}.qcow2.bz2` which can then be uploaded to Digital Ocean and used to create your droplet. Check out their instructions at https://blog.digitalocean.com/custom-images/ for uploading the image and creating your droplet.

In this commit, the script will produce alpine `version 3.15` image. If you wanna build latest version, you can pull latest [alpine-make-vm-image repo](https://github.com/alpinelinux/alpine-make-vm-image): `git submodule foreach git pull origin master`

### Building
#### From Builder
1. sudo apt update && sudo apt install -y qemu-utils bzip2 e2fsprogs git
2. git clone https://github.com/viral-vector/alpine-droplet.git
3. cd alpine-droplet && git branch <vgn>
4. git submodule update --init --recursive
5. git submodule foreach git pull origin master
6. sudo ./build-image.sh
#### Fetch from Builder
7. scp root@<builder-ip>:/root/alpine-droplet/alpine-virt-image-*.qcow2.bz2 .
