# wa-vault: the provider-key broker (see docs/VAULT.md). Standard library only, so the image is the
# interpreter and two files. Runs as its own unprivileged user with its own volume at /data; the
# agent's container never mounts that volume.
FROM python:3.13-alpine
RUN adduser -D -H -u 10001 vault && mkdir -p /data /opt/wa-vault && chown vault:vault /data && chmod 700 /data
COPY wa_vault.py /opt/wa-vault/wa_vault.py
COPY page/ /opt/wa-vault/page/
USER vault
ENV WA_VAULT_DATA=/data PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8801 8810
CMD ["python3", "/opt/wa-vault/wa_vault.py"]
