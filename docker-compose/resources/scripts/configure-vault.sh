#!/bin/bash

CONTAINER_NAME="vault"

# Configure Vault with initial settings
configure_vault() {
    # Login with root token
    ROOT_TOKEN=$(jq -r '.root_token' resources/config/cluster-keys.json)
    docker exec ${CONTAINER_NAME} vault login ${ROOT_TOKEN}

    # Enable userpass auth method
    echo "Enabling userpass auth method..."
    docker exec ${CONTAINER_NAME} vault auth enable userpass

    # Create admin policy
    echo "Creating admin policy..."
    cat > policy.hcl << EOF
path "auth/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/auth/*"
{
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/auth"
{
  capabilities = ["read", "list"]
}

path "sys/policies/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "transit/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/userpass/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/userpass/users/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

    docker cp policy.hcl ${CONTAINER_NAME}:/tmp/policy.hcl
    docker exec ${CONTAINER_NAME} vault policy write admin /tmp/policy.hcl
    rm policy.hcl

    # Create non-root user policy
    echo "Creating non-root user policy..."
    cat > nonroot-policy.hcl << EOF
path "transit/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

    docker cp nonroot-policy.hcl ${CONTAINER_NAME}:/tmp/nonroot-policy.hcl
    docker exec ${CONTAINER_NAME} vault policy write nonroot /tmp/nonroot-policy.hcl
    rm nonroot-policy.hcl

    # Create admin user
    echo "Creating admin user..."
    docker exec ${CONTAINER_NAME} vault write auth/userpass/users/admin \
        password=admin \
        policies=admin

    # Enable transit engine
    echo "Enabling transit secrets engine..."
    docker exec ${CONTAINER_NAME} vault secrets enable transit
}

main() {
    configure_vault
    
    echo "Vault setup complete!"
    echo "Admin credentials - username: admin, password: admin"
}

main