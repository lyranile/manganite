# Throw-away image used only to build the installer ISO.
ARG BASE_IMAGE=ghcr.io/lyranile/manganite:latest
FROM ${BASE_IMAGE}

COPY fedora.repo /etc/yum.repos.d/fedora.repo
