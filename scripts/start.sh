#!/usr/bin/env bash
# start.sh - container entrypoint, the way RunPod's own templates start SSH.
# Adds the PUBLIC_KEY env var to authorized_keys, starts sshd on port 22, then
# stays in the foreground so the pod keeps running. A job SSHes in and works.
set -e

mkdir -p /run/sshd ~/.ssh
chmod 700 ~/.ssh

# RunPod passes the pod's public key in PUBLIC_KEY. Append it (one per line).
if [ -n "${PUBLIC_KEY:-}" ]; then
  echo "${PUBLIC_KEY}" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
fi

# Host keys (generated once if the image did not ship them).
ssh-keygen -A

# Make the pod env (CUDA paths, HF cache) visible to SSH sessions, which do not
# read the Docker ENV. RunPod templates do exactly this.
# /etc/profile.d loads for LOGIN shells (interactive ssh).
printenv | grep -E '^(PATH|LD_LIBRARY_PATH|CUDA|HF_|HUGGINGFACE|PYTHON|VK_ICD|XDG_|NVIDIA_)' \
  | sed 's/^/export /' > /etc/profile.d/pod_env.sh 2>/dev/null || true
# /etc/environment is read by PAM for ALL sessions, including `ssh host '<cmd>'`
# (non-login, non-interactive) — which is how jobs and the smoke test run. Write
# the non-PATH vars there so VK_ICD_FILENAMES / XDG_RUNTIME_DIR / HF_* are set in
# those sessions too (leave PATH/LD_LIBRARY_PATH to profile.d to avoid clobbering
# the default login PATH with a bare value).
printenv | grep -E '^(CUDA|HF_|HUGGINGFACE|PYTHON|VK_ICD|XDG_|NVIDIA_)' \
  >> /etc/environment 2>/dev/null || true

echo "card-images: sshd starting on port 22"
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# If the pod was given a command, run it; otherwise wait on sshd.
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  wait "$SSHD_PID"
fi
