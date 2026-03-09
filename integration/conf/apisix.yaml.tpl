routes:
  - id: 1
    uri: /*
    upstream:
      nodes:
        "httpbin:8080": 1
      type: roundrobin

ssls:
  - id: 1
    cert: |
      __CERT__
    key: |
      __KEY__
    snis:
      - "test.example.com"
      - "*.test.example.com"
#END
