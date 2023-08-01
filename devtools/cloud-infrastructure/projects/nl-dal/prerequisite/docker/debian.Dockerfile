ARG SOURCE_IMAGE
FROM $SOURCE_IMAGE:latest
# openssh-server is needed for sshd
# python3 is not strictly needed but could be used to run an html server for example
RUN apt update && apt install libgmp-dev curl libev-dev libhidapi-dev python3 openssh-server -y
# This directory is necessary for running sshd
RUN mkdir -p /run/sshd
# A server ssh also requires a key. We generate one for all the main schemes
RUN mkdir -p /root/.ssh
RUN ssh-keygen -A
# The public key giving access in ssh to the container
ARG SSH_PUBLIC_KEY
# The key is added to already existing keys
RUN echo $SSH_PUBLIC_KEY >> /root/.ssh/authorized_keys
# Copy zcash params from local machine to the remote one
ARG ZCASH_PARAMS_PATH
COPY $ZCASH_PARAMS_PATH /usr/local/share/zcash-params
# We run the ssh server but not as a daemon on the port 30000
CMD /usr/sbin/sshd -D -p 30000 -e
