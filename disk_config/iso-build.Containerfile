# Throw-away image used only to build the installer ISO.
ARG BASE_IMAGE=ghcr.io/lyranile/manganite:latest
FROM ${BASE_IMAGE}

# The installer packages are resolved from the repositories of the image the
# builder is given, and Universal Blue images ship no Fedora repository. Add
# Fedora for the build and keep terra out of it, so the installer environment
# is resolved from Fedora only and stays reproducible.
COPY fedora.repo /etc/yum.repos.d/fedora.repo
RUN sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/terra.repo
