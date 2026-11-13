# OpenBao for the Docker Compose platform: the wallet's KMS (the Transit
# engine; the wallet logs in with userpass). One node with integrated
# storage (raft) in the volume openbao-data.
#
# Unseal: the static seal unseals OpenBao at each start with the key file
# from make secrets (secrets/openbao/static-seal.key, 32 random bytes), so
# nobody has to unseal it by hand. Keep that file safe: without it, nobody
# can read OpenBao's data (the signing keys of the organisations).
#
# No TLS: port 8200 is only on the Compose network (no host port).
ui            = false
disable_mlock = true
api_addr      = "http://openbao:8200"
cluster_addr  = "http://openbao:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-0"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

seal "static" {
  current_key_id = "compose-1"
  current_key    = "file:///run/secrets/openbao/static-seal.key"
}
