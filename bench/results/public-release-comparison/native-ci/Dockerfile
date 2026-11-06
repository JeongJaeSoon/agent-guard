FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 jq curl perl git ca-certificates procps time strace && rm -rf /var/lib/apt/lists/*
WORKDIR /experiment
ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENTRYPOINT ["python3", "/experiment/run.py"]
