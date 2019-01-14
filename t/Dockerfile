# DOCKER_NAME=deployment-iso-stretch
FROM docker.mgm.sipwise.com/sipwise-stretch:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT 2018-03-20

RUN apt-get update && apt-get install --assume-yes git make gcc dpkg-dev

RUN echo './t/testrunner' >>/root/.bash_history

WORKDIR /code/

################################################################################
# Instructions for usage
# ----------------------
# When you want to build the base image from scratch
# jump to the next section if you don't want to build yourself!:
#
# % docker build --tag="lua-ngcp-kamailio-stretch" -f t/Dockerfile .
# % docker run --rm -i -t -v $(pwd):/code:rw lua-ngcp-kamailio-stretch:latest bash
#
# Use the existing docker image:
# % docker pull docker.mgm.sipwise.com/lua-ngcp-kamailio-stretch
# NOTE: run the following command from root folder of git repository:
# % docker run --rm -i -t -v $(pwd):/code:rw docker.mgm.sipwise.com/lua-ngcp-kamailio-stretch:latest bash
#
# Inside docker (the command is in history, just press UP button):
#   ./t/testrunner
#
################################################################################
