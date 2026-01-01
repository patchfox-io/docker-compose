# docker-compose

![docker-image.jpg](docker-image.jpg)

## what is this? 

This is how you spin up all of the PatchFox services on your workstation. It contains 

* `build_images.sh` that will create fresh docker images for every PatchFox service 
* `docker-compose.yml` that will spin up all the services, kafka, zookeeper, and postgres 

## how do I use it? 

1. Ensure all the PatchFox services from the [services](https://gitlab.com/patchfox2/services) group are cloned and co-located in the sasme filesystem directory. 

2. Ensure this repository is cloned in the same directory to which you cloned the PatchFox services.

3. Run `build_images.sh`. This will create fresh docker images for all services.

4. Execute command `docker-compose up` or `docker compose up` - depending on your installation. This will bring up all the things. 

## what are the host port mappings for the services? 

| service | host port |
| ------ | ------ |
| analyze-service | 1701 |
| data-service | 1702 |
| forecast-service | 1703 |
| grype-service | 1704 |
| input-servce | 1705 |
| nvd-service | 1706 |
| orchestrate-service | 1707 |
| package-index-service | 1708 |
| recommend-service | 1709 |

## what is the db host port mapping? 

Postgres is accessible to host on port `55432`


🍻









