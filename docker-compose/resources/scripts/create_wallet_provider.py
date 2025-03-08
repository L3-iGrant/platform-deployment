import logging
import requests
import urllib3

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Disable InsecureRequestWarning
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Get base URL from environment variable or use default
BASE_URL = "http://localhost:8080"


def make_authorized_post_request(url, payload, token):
    headers = {
        "Content-Type": "application/json",
    }

    if token:
        headers["Authorization"] = f"Bearer {token}"

    response = requests.post(url, json=payload, headers=headers, verify=False)

    return response


def register_admin(username: str, name: str, password: str, phone: str):
    url = f"{BASE_URL}/v2/onboard/admin/register"
    payload = {
        "username": username,
        "name": name,
        "password": password,
        "phone": phone,
    }

    response = requests.post(
        url,
        json=payload,
        headers={"Content-Type": "application/json"},
        verify=False,
    )
    if response.status_code != 201:
        raise Exception(
            f"Failed to register admin. Status code: {response.status_code}"
        )


def login_admin(username: str, password: str) -> str:
    url = f"{BASE_URL}/v2/onboard/admin/login"
    payload = {"username": username, "password": password}

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to login admin. Status code: {response.status_code}"
        )

    return response.json()["accessToken"]


def create_organisation_type(token: str, org_type: str):
    url = f"{BASE_URL}/v2/onboard/organisation/type"
    payload = {"type": org_type}

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 201:
        raise Exception(
            f"Failed to create organisation type. Status code: {response.status_code}"
        )


def get_organisation_types(
    token: str, offset: int = 0, limit: int = 10
) -> dict:
    url = f"{BASE_URL}/v2/onboard/organisation/types?offset={offset}&limit={limit}"

    response = requests.get(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to get organisation types. Status code: {response.status_code}"
        )

    return response.json()


def create_organisation(
    token: str,
    name: str,
    location: str,
    description: str,
    policyUrl: str,
    typeId: str,
):
    url = f"{BASE_URL}/v2/onboard/organisation"
    payload = {
        "location": location,
        "name": name,
        "description": description,
        "policyUrl": policyUrl,
        "typeId": typeId,
    }

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to create organisation. Status code: {response.status_code}"
        )


def update_organisation_wallet_features(token: str):
    url = f"{BASE_URL}/v2/onboard/organisation/features"
    payload = {
        "gettingStarted": True,
        "dataAgreements": False,
        "managedData": False,
        "digitalWalletAries": False,
        "digitalWalletOid4vc": True,
        "manageUsers": False,
        "privacyDashboard": False,
        "account": True,
        "supportEvents": True,
    }

    response = requests.put(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to create organisation. Status code: {response.status_code}"
        )


def enable_wallet_provider(token: str):
    url = f"{BASE_URL}/v2/config/digital-wallet/openid"

    payload = {
        "isWalletProvider": True,
    }

    response = requests.put(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to update wallet unit configuration. Status code: {response.status_code}"
        )

    return response.json()


def deploy_organisation_wallet(token: str):
    url = f"{BASE_URL}/v2/config/digital-wallet/openid"
    payload = {}

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to deploy organisation. Status code: {response.status_code}"
        )

    return response.json()


def configure_wallet_key_management(token: str, secure_vault: int = 1):
    url = (
        f"{BASE_URL}/v2/config/digital-wallet/openid/key-management"
    )
    payload = {"secureVault": secure_vault}

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 201:
        raise Exception(
            f"Failed to configure wallet key management. Status code: {response.status_code}"
        )

    return response.json()


def create_credential_definition(token: str):
    url = f"{BASE_URL}/v2/config/digital-wallet/openid/sdjwt/credential-definition"
    payload = {
        "label": "Wallet Unit Attestation",
        "expirationInDays": 30,
        "supportRevocation": True,
        "display": {
            "name": "",
            "description": "",
            "backgroundColor": "",
            "textColor": "",
        },
        "credentialFormat": "dc+sd-jwt",
        "vct": "WalletUnitAttestation",
        "claims": {
            "type": "object",
            "properties": {
                "attested_security_context": {
                    "type": "string",
                    "limitDisclosure": False,
                }
            },
            "additionalProperties": True,
            "required": ["attested_security_context"],
        },
    }

    response = requests.post(
        url,
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:  # Changed from 201 to 200
        raise Exception(
            f"Failed to create credential definition. Status code: {response.status_code}"
        )

    return response.json()


if __name__ == "__main__":
    admin_email = "admin@walletprovider.local"
    admin_password = "qwerty123"

    logger.info("👤 Registering admin user...")
    register_admin(
        username=admin_email,
        name="Admin",
        password=admin_password,
        phone="+1322222222",
    )

    logger.info("🔑 Logging in admin user...")
    token = login_admin(username=admin_email, password=admin_password)

    logger.info("🏢 Creating organisation type...")
    create_organisation_type(token=token, org_type="Technology")

    logger.info("📋 Getting organisation types...")
    org_types = get_organisation_types(token=token)
    typeId = org_types["organisationTypes"][0]["id"]

    name = "Wallet Provider (Local)"
    location = "Kochi"
    policyUrl = "https://walletprovider.local/policy"

    logger.info("🏗️ Creating organisation...")
    create_organisation(
        token=token,
        name=name,
        location=location,
        policyUrl=policyUrl,
        typeId=typeId,
        description="Wallet provider",
    )

    logger.info("⚙️ Updating organisation wallet features...")
    update_organisation_wallet_features(token=token)

    logger.info("🚀 Deploying organisation wallet...")
    deployment = deploy_organisation_wallet(token=token)
    logger.info(
        f"🔗 Agent Service Endpoint: {deployment['agentServiceEndpoint']}"
    )
    logger.info(
        "\n🚨 IMPORTANT: Please configure the agent service endpoint in your .envrc file:"
    )
    logger.info(
        f"📝 export WALLET_PROVIDER_BASE_URL={deployment['agentServiceEndpoint']}"
    )
    logger.info(
        "🔄 Then rerun Organisation Wallet by executing: poetry run start-server"
    )

    logger.info("✅ Enabling wallet provider...")
    enable_wallet_provider(token=token)

    logger.info("🔐 Configuring wallet key management...")
    configure_wallet_key_management(token=token, secure_vault=1)

    logger.info("📜 Creating credential definition...")
    create_credential_definition(token=token)

    logger.info("🎉 Setup completed successfully!")
