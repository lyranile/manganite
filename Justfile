set dotenv-filename := "image-template.env"
set dotenv-load

export image_name := env("IMAGE_NAME")
export repo_organization := env("REPO_ORGANIZATION")
export image_desc := env("IMAGE_DESC")
export image_keywords := env("IMAGE_KEYWORDS")
export image_logo_url := env("IMAGE_LOGO_URL")
export default_tag := env("DEFAULT_TAG")
export bib_image := env("BIB_IMAGE")

export PODMAN := "podman"
export BUILDAH := "buildah"
export SUDOIF := if `id -u` == "0" { "" } else { "sudo" }

# VM run defaults
vm_host := "127.0.0.1"
vm_port := "8006"
qemu_image := "docker.io/qemux/qemu"
alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
# Pre-rename alias, also used dynamically by `_run` as `build-${type}`
alias build-iso := build-installer-iso

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    rm -rf _build* output sbom_out
    rm -f previous.manifest.json changelog.md output.env /tmp/*-tags.json

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif: run a command as root, via sudo when not root
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/env bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# Build the container image with Podman.
# Labels include the short SHA of HEAD when the git worktree is clean.
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -euox pipefail

    LABELS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/{{ repo_organization }}/{{ image_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.documentation=https://raw.githubusercontent.com/{{ repo_organization }}/{{ image_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ image_name }}/blob/${GIT_SHA}/Containerfile")
        LABELS+=("--label" "org.opencontainers.image.url=https://github.com/{{ repo_organization }}/{{ image_name }}/tree/${GIT_SHA}")
        LABELS+=("--label" "org.opencontainers.image.version={{ default_tag }}.$(date +%Y%m%d)-${GIT_SHA}")
    fi

    # Metadata for https://artifacthub.io/ (optional, recommended)
    LABELS+=("--label" "io.artifacthub.package.deprecated=false")
    LABELS+=("--label" "io.artifacthub.package.keywords={{ image_keywords }}")
    LABELS+=("--label" "io.artifacthub.package.license=Apache-2.0")
    LABELS+=("--label" "io.artifacthub.package.logo-url={{ image_logo_url }}")
    LABELS+=("--label" "io.artifacthub.package.prerelease=false")
    LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("--label" "org.opencontainers.image.description={{ image_desc }}")
    LABELS+=("--label" "org.opencontainers.image.title={{ image_name }}")
    LABELS+=("--label" "org.opencontainers.image.vendor={{ repo_organization }}")

    PODMAN_BUILD_ARGS=("${LABELS[@]}" --pull=newer --tag "${target_image}:${tag}" --file Containerfile --build-arg "NVIDIA_VARIANT=${NVIDIA_VARIANT:-open}")

    podman build "${PODMAN_BUILD_ARGS[@]}" .

# Split the image into layers for smaller updates (chunkah)
rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -xeuo pipefail

    # This makes a full copy of the image; may exhaust disk on CI runners
    # unless the base image also uses chunkah.
    CHUNKAH_PIN_FILE="{{ justfile_directory() }}/tools/chunkah/Dockerfile"

    if [[ ! -f "${CHUNKAH_PIN_FILE}" ]]; then
        echo "Missing chunkah pin file: ${CHUNKAH_PIN_FILE}" >&2
        exit 1
    fi

    CHUNKAH_IMAGE="$(awk '$1 == "FROM" { print $2; exit }' "${CHUNKAH_PIN_FILE}")"

    if [[ -z "${CHUNKAH_IMAGE}" ]]; then
        echo "No FROM image found in ${CHUNKAH_PIN_FILE}" >&2
        exit 1
    fi

    CHUNKAH_CONFIG_FILE="$(mktemp)"

    # Build in ./ (not /tmp) to avoid /tmp space limits
    CHUNKAH_OUTPUT_DIR="$(mktemp -d ./"${target_image}"_chunkah_XXXXXX)"

    trap 'rm -f "${CHUNKAH_CONFIG_FILE}"; rm -rf "${CHUNKAH_OUTPUT_DIR}"' EXIT
    podman inspect "${target_image}:${tag}" > "${CHUNKAH_CONFIG_FILE}"

    podman run --rm \
      --mount=type=image,src="${target_image}:${tag}",target=/chunkah \
      -v "${CHUNKAH_CONFIG_FILE}:/chunkah-config.json:ro,Z" \
      -v "${CHUNKAH_OUTPUT_DIR}:/run/out:Z" \
      "${CHUNKAH_IMAGE}" \
      build \
      --verbose \
      --compressed \
      --max-layers 128 \
      --prune /sysroot/ \
      --label ostree.commit- --label ostree.final-diffid- \
      --config /chunkah-config.json \
      --output oci:/run/out/chunked

    CHUNKED_IMAGE="$(podman pull "oci:${CHUNKAH_OUTPUT_DIR}/chunked")"
    podman tag "${CHUNKED_IMAGE}" "${target_image}:${tag}"

# Split the image into layers for smaller updates (rpm-ostree)
ostree-rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -xeuo pipefail

    # Use the already-built local image to avoid pulling from a remote registry
    RPM_OSTREE_CHUNKER_IMAGE="localhost/${target_image}:${tag}"

    GRAPHROOT="$(podman info --format '{{ '{{.Store.GraphRoot}}' }}')"

    podman run --rm --pull=never --privileged \
      --mount=type=image,src="${target_image}:${tag}",target=/rpm-ostree \
      --mount=type=bind,src=${GRAPHROOT},target=/run/host-container-storage,rw \
      --mount=type=tmpfs,target=/run/rpm-ostree-storage \
      --entrypoint /usr/bin/rpm-ostree \
      "${RPM_OSTREE_CHUNKER_IMAGE}" \
      compose build-chunked-oci \
      --max-layers 127 \
      --format-version=2 \
      --bootc \
      --rootfs /rpm-ostree \
      --output "containers-storage:[overlay@/run/host-container-storage+/run/rpm-ostree-storage]localhost/${target_image}:${tag}"

# Generate Default Tag
[group('Utility')]
generate-default-tag $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${tag}"

# Generate Tags
[group('Utility')]
generate-build-tags $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    DATE=$(date +%Y%m%d)
    BUILD_TAGS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        BUILD_TAGS+=("${tag}-${GIT_SHA}")
        BUILD_TAGS+=("${tag}-${DATE}-${GIT_SHA}")
        BUILD_TAGS+=("${DATE}-${GIT_SHA}")
    fi

    BUILD_TAGS+=("${DATE}")
    BUILD_TAGS+=("${tag}")
    BUILD_TAGS+=("${tag}-${DATE}")

    echo "${BUILD_TAGS[@]}"

# Tag Images
[group('Utility')]
tag-images $target_image=image_name $tag=default_tag tags="":
    #!/usr/bin/env bash
    set -eoux pipefail

    IMAGE=$(podman inspect ${target_image}:${tag} | jq -r .[].Id)
    podman untag ${IMAGE}

    for tag in {{ tags }}; do
        podman tag $IMAGE "${target_image}:${tag}"
    done

    podman images

# Image Name
[group('Utility')]
[private]
image_name $target_image=image_name:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${image_name}"

# Load the image into rootful podman, or pull it remotely if missing
_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    set +e
    podman inspect -t image "${target_image}:${tag}" > /dev/null
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Build a bootable disk image from the container image via Bootc Image Builder (BIB)
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)
    GPGDIR=$(mktemp -d "${PWD}/_build-bib-gpg.XXXXXXXXXX")
    trap 'rm -rf "${GPGDIR}"' EXIT
    sudo podman run --rm \
      -v "${GPGDIR}":/out:Z \
      "${target_image}:${tag}" \
      bash -c 'cp -aL /etc/pki/rpm-gpg/. /out/ 2>/dev/null || true; cp -aL /usr/share/pki/rpm-gpg/. /out/ 2>/dev/null || true'

    if [[ "${type}" == "iso" ]]; then
      ISO_IMAGE="localhost/$(basename "${target_image}")-iso-build:latest"
      sudo podman build \
        --build-arg "BASE_IMAGE=${target_image}:${tag}" \
        -t "${ISO_IMAGE}" \
        -f "$(pwd)/disk_config/iso-build.Containerfile" \
        "$(pwd)/disk_config"

      sudo podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --net=host \
        --security-opt label=type:unconfined_t \
        -v "${GPGDIR}":/etc/pki/rpm-gpg:ro,Z \
        -v "${GPGDIR}":/usr/share/pki/rpm-gpg:ro,Z \
        -v "$(pwd)/${config}":/config.toml:ro \
        -v "${BUILDTMP}":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        --type iso \
        --rootfs btrfs \
        --use-librepo=True \
        "${ISO_IMAGE}"
    else
      args="--type ${type} "
      args+="--use-librepo=True "
      args+="--rootfs=btrfs"

      sudo podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --net=host \
        --security-opt label=type:unconfined_t \
        -v "${GPGDIR}":/etc/pki/rpm-gpg:ro,Z \
        -v "${GPGDIR}":/usr/share/pki/rpm-gpg:ro,Z \
        -v "$(pwd)/${config}":/config.toml:ro \
        -v "${BUILDTMP}":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        ${args} \
        "${target_image}:${tag}"
    fi

    rm -rf output
    mkdir -p output
    sudo mv -f "${BUILDTMP}"/* output/
    sudo rmdir "${BUILDTMP}"
    sudo chown -R $USER:$USER output/

# Build the container image, then create a bootable disk image via BIB
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtual Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build an installer ISO (bootc generic-iso) via Bootc Image Builder
[group('Build Virtual Machine Image')]
build-installer-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtual Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild an ISO virtual machine image
[group('Build Virtual Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: (build target_image tag)
    just build-installer-iso ${target_image} ${tag}

# Run a virtual machine with the specified image type and configuration
_run $target_image $tag $type $config:
    #!/usr/bin/env bash
    set -eoux pipefail

    # Determine the image file based on the type
    if [[ "${type}" == "iso" ]]; then
        image_file="$(find output -type f -iname '*.iso' 2>/dev/null | head -n1 || true)"
    else
        image_file="output/${type}/disk.${type}"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    vm_host={{ vm_host }}
    port={{ vm_port }}
    while grep -q ":${port}" <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://${vm_host}:${port}"

    qemu_image={{ qemu_image }}

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "${vm_host}:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}":Z)
    run_args+=(${qemu_image})

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtual Machine')]
run-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtual Machine')]
run-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from the installer ISO
[group('Run Virtual Machine')]
run-iso $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    image_file="$(find output -type f -iname '*.iso' 2>/dev/null | head -n1 || true)"
    if [[ ! -f "${image_file}" ]]; then
        just build-installer-iso ${target_image} ${tag}
        image_file="$(find output -type f -iname '*.iso' 2>/dev/null | head -n1 || true)"
    fi
    vm_host={{ vm_host }}
    port={{ vm_port }}
    qemu_image={{ qemu_image }}
    while grep -q ":${port}" <<< $(ss -tunalp); do port=$(( port + 1 )); done
    echo "Using Port: ${port}"
    podman run --rm --privileged --pull=newer --publish "${vm_host}:${port}:8006" \
        --env "CPU_CORES=4" --env "RAM_SIZE=8G" --env "DISK_SIZE=64G" \
        --env "TPM=Y" --env "GPU=Y" --device=/dev/kvm \
        --volume "${PWD}/${image_file}":"/boot.iso":Z \
        ${qemu_image}

# Run a virtual machine using systemd-vmspawn
[group('Run Virtual Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    if [[ "{{ rebuild }}" -eq 1 ]]; then
        echo "Rebuilding the {{ type }} image"
        just "build-{{ type }}"
    fi

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}

# Run shellcheck on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Run shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    if ! command -v shfmt &> /dev/null; then
        echo "shfmt could not be found. Please install it."
        exit 1
    fi
    find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

# Run Container
[group('Utility')]
run $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    ${PODMAN} run -it --rm "${target_image}:${tag}" bash

# Create bootable disk image
[group('Utility')]
disk-image $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    IMG_SIZE=40G
    BYTES_IMAGE_SIZE=$(numfmt --from=iec ${IMG_SIZE})
    if [ ! -e "./bootable.img" ]; then
        fallocate -l "${BYTES_IMAGE_SIZE}" "./bootable.img"
    fi
    ${SUDOIF} ${PODMAN} run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "${PWD}:/data" \
        "${target_image}:${tag}" \
        bootc install to-disk --generic-image --via-loopback /data/bootable.img --wipe --bootloader grub

# Export OCI archive for PR testing
[group('Utility')]
export-oci $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    ARCHIVE_NAME="${target_image##*/}-$(arch).oci"
    ${PODMAN} push --compression-format=zstd --compression-level=3 \
        "${target_image}:${tag}" "oci-archive:${ARCHIVE_NAME}"

# Run bootc commands inside the image
[group('Utility')]
bootc $target_image=image_name $tag=default_tag *ARGS:
    #!/usr/bin/env bash
    set -eoux pipefail
    ${PODMAN} run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "${PWD}:/data" \
        "${target_image}:${tag}" bootc {{ ARGS }}

# Secure Boot signature check
[group('Utility')]
secureboot $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    kernel_release=$(${PODMAN} inspect "${target_image}:${tag}" | jq -r '.[].Config.Labels["ostree.linux"]')
    TMP=$(${PODMAN} create "${target_image}:${tag}" bash)
    ${PODMAN} cp "$TMP":/usr/lib/modules/"${kernel_release}"/vmlinuz /tmp/vmlinuz
    ${PODMAN} rm "$TMP"
    curl --retry 3 -Lo /tmp/akmods.der https://github.com/ublue-os/akmods/raw/main/certs/public_key.der
    openssl x509 -in /tmp/akmods.der -out /tmp/akmods.crt 2>/dev/null || true
    CMD="$(command -v sbverify || true)"
    if [[ -z "${CMD:-}" ]]; then
        temp_name="sbverify-${RANDOM}"
        ${PODMAN} run -dt --entrypoint /bin/sh \
            --volume /tmp/vmlinuz:/tmp/vmlinuz:z \
            --volume /tmp/akmods.crt:/tmp/akmods.crt:z \
            --name "${temp_name}" docker.io/library/alpine:edge
        ${PODMAN} exec "${temp_name}" apk add sbsigntool >/dev/null
        CMD="${PODMAN} exec ${temp_name} /usr/bin/sbverify"
    fi
    $CMD --list /tmp/vmlinuz
    if ! $CMD --cert /tmp/akmods.crt /tmp/vmlinuz; then
        echo "Secure Boot signature check failed."
        [[ -n "${temp_name:-}" ]] && ${PODMAN} rm -f "${temp_name}"
        exit 1
    fi
    [[ -n "${temp_name:-}" ]] && ${PODMAN} rm -f "${temp_name}"
    echo "Secure Boot signature check passed."

# Generate SBOM
[group('Utility')]
gen-sbom $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    OUT_DIR="sbom_out/${target_image##*/}"
    mkdir -p "${OUT_DIR}"
    ${PODMAN} container create --replace --name "${target_image##*/}" "${target_image}:${tag}"
    ROOTFS="${OUT_DIR}/rootfs"
    mkdir -p "${ROOTFS}"
    ${PODMAN} export "${target_image##*/}" | tar -C "${ROOTFS}" -xf -
    ${PODMAN} container rm "${target_image##*/}"
    if command -v syft >/dev/null 2>&1; then
        syft --source-name "${target_image}:${tag}" "${OUT_DIR}" -o "syft-json=${OUT_DIR}/sbom.json"
    else
        echo "syft not found; rootfs exported to ${ROOTFS}"
    fi
    rm -rf "${ROOTFS}"
