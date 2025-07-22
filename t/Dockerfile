# DOCKER_NAME=deployment-iso-trixie
FROM docker.mgm.sipwise.com/sipwise-trixie:latest

# Important! Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apt-get update` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2025-07-22

RUN apt-get update && apt-get install --assume-yes git make gcc dpkg-dev

RUN git config --global --add safe.directory /code

RUN echo './t/testrunner' >>/root/.bash_history

WORKDIR /code/

################################################################################
# Instructions for usage
# ----------------------
# When you want to build the base image from scratch
# jump to the next section if you don't want to build yourself!:
#
# % docker build --tag="deployment-iso-trixie" -f t/Dockerfile .
# % docker run --rm -i -t -v $(pwd):/code:rw deployment-iso-trixie:latest bash
#
# Use the existing docker image:
# % docker pull docker.mgm.sipwise.com/deployment-iso-trixie
# NOTE: run the following command from root folder of git repository:
# % docker run --rm -i -t -v $(pwd):/code:rw docker.mgm.sipwise.com/deployment-iso-trixie:latest bash
#
# Inside docker (the command is in history, just press UP button):
#   ./t/testrunner
#
################################################################################
