import logging
import requests
import urllib3
import os

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
    url = f"{BASE_URL}/v2/config/digital-wallet/openid/key-management"
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


def configure_request_wallet_unit_attestaion(token: str):
    url = f"{BASE_URL}/v2/config/digital-wallet/openid/wallet-unit/request"

    response = requests.post(
        url,
        json={},
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        verify=False,
    )

    if response.status_code != 200:
        raise Exception(
            f"Failed to configure wallet key management. Status code: {response.status_code}"
        )


if __name__ == "__main__":
    logger.info("🚀 Starting wallet units creation process...")

    # Create and login multiple admin accounts with different seeds
    admin_tokens = {}  # Use dict instead of list to map emails to tokens
    for seed in range(1, 6):  # Create admin accounts
        admin_email = f"admin{seed}@igrant.io"
        admin_password = "qwerty123"
        logger.info(f"👤 Creating admin {seed}: {admin_email}")
        admin_name = f"Admin {seed}"
        admin_phone = f"+12345{seed}"
        register_admin(
            username=admin_email,
            name=admin_name,
            password=admin_password,
            phone=admin_phone,
        )

        # Login each admin and map their token to their email
        logger.info(f"🔑 Logging in admin {seed}...")
        token = login_admin(username=admin_email, password=admin_password)
        admin_tokens[admin_email] = token

    # Use first admin token to create an organisation type
    first_admin_token = next(iter(admin_tokens.values()))

    # Get organisation types and retrieve the first one
    logger.info("📋 Getting organisation types...")
    org_types = get_organisation_types(token=first_admin_token)
    typeId = org_types["organisationTypes"][0]["id"]

    for seed in range(1, 6):
        logger.info(f"🏢 Setting up organization {seed}...")
        token = admin_tokens[f"admin{seed}@igrant.io"]
        name = f"Organization {seed}"
        location = f"Location {seed}"
        policyUrl = f"https://org{seed}.example.com/policy"

        logger.info(f"📝 Creating organization {seed}...")
        create_organisation(
            token=token,
            name=name,
            location=location,
            policyUrl=policyUrl,
            typeId=typeId,
            description=f"Test organization {seed}",
        )

        logger.info(f"⚙️ Configuring wallet features for org {seed}...")
        update_organisation_wallet_features(token=token)

        logger.info(f"🚀 Deploying wallet for org {seed}...")
        deploy_organisation_wallet(token=token)

        logger.info(f"🔐 Setting up key management for org {seed}...")
        configure_wallet_key_management(token=token, secure_vault=1)

        logger.info(f"📜 Configuring wallet unit attestation for org {seed}...")
        configure_request_wallet_unit_attestaion(token=token)

        logger.info(f"✅ Organization {seed} setup complete!")

    logger.info("🎉 All wallet units created successfully!")
