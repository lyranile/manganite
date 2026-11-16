# Throw-away image used only to build the installer ISO.
ARG BASE_IMAGE=ghcr.io/lyranile/manganite:latest
FROM ${BASE_IMAGE}

# The installer packages are resolved from the repositories of the image the
# builder is given, and Universal Blue images ship no Fedora repository. Add
# Fedora for the build only - this image is never published, the ISO installs
# the real image (the reference is baked into the kickstart).
COPY fedora.repo /etc/yum.repos.d/fedora.repo
