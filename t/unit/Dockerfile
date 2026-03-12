FROM openresty/openresty:jammy

RUN luarocks install busted

COPY . /src
WORKDIR /src
RUN luarocks make

WORKDIR /src/t/unit
CMD ["busted", "--verbose", "spec/"]
