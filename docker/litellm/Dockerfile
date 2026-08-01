# The LiteLLM proxy, with its config BAKED IN.
#
# The containment contract forbids host bind mounts, and the usual way to run
# litellm is `-v ./config.yaml:/app/config.yaml`. Deriving a one-layer image
# instead keeps the config in the image and the host filesystem out of the
# deployment entirely. Secrets stay in the environment (see config.yaml).
FROM ghcr.io/berriai/litellm:main-stable

COPY config.yaml /etc/litellm/config.yaml

CMD ["--config", "/etc/litellm/config.yaml", "--port", "4000", "--host", "0.0.0.0"]
