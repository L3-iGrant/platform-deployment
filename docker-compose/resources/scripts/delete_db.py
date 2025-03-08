from pymongo import MongoClient
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
import subprocess
import logging
import requests

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def get_relevant_processes():
    """Fetch all running kubectl and k9s processes."""
    try:
        # Run two separate commands to get kubectl and k9s processes
        kubectl_result = subprocess.run(
            ["pgrep", "-fl", "kubectl"], capture_output=True, text=True
        )
        k9s_result = subprocess.run(
            ["pgrep", "-fl", "k9s"], capture_output=True, text=True
        )

        # Combine and filter results
        processes = []
        if kubectl_result.stdout:
            processes.extend(kubectl_result.stdout.strip().split("\n"))
        if k9s_result.stdout:
            processes.extend(k9s_result.stdout.strip().split("\n"))

        return [p for p in processes if p]  # Filter out empty strings

    except FileNotFoundError:
        logger.error("Error: pgrep command not found. Ensure it is installed.")
        return []


def filter_port_forward_processes(processes):
    """Filter processes that are either 'kubectl port-forward' or 'k9s' and contain 'mongo'."""
    filtered = []
    for proc in processes:
        parts = proc.split()
        if "port-forward" in proc or "k9s" in parts:
            filtered.append(proc)
    return filtered


def kill_processes(processes):
    """Kill filtered processes."""
    for proc in processes:
        pid = proc.split()[0]  # Extract the PID
        try:
            subprocess.run(["kill", "-9", pid], check=True)
            logger.info(f"✅ Terminated process: {proc}")
        except subprocess.CalledProcessError:
            logger.error(f"❌ Failed to kill process: {proc}")


def delete_mongodb():
    """Delete all collections from MongoDB."""
    logger.info("🗑️ Cleaning MongoDB database...")

    # MongoDB connection details
    username = "admin"
    password = "Nin0t73D5Uqi"
    host = "localhost"
    port = "27017"  # Default MongoDB port

    # Create connection URI
    connection_uri = f"mongodb://{username}:{password}@{host}:{port}"

    try:
        # Connect to MongoDB
        client = MongoClient(connection_uri)

        # Get database
        db = client["igrant-consentdb"]

        # Truncate all collections
        for collection in db.list_collection_names():
            result = db[collection].delete_many({})
            logger.info(
                f"🗑️ Deleted {result.deleted_count} documents from collection: {collection}"
            )

        logger.info("✅ Successfully truncated all collections in MongoDB")

    except Exception as e:
        logger.error(f"❌ Error truncating MongoDB collections: {str(e)}")

    finally:
        client.close()


def delete_postgresql():
    """Truncate all tables in the PostgreSQL database except alembic_version."""
    logger.info("🗑️ Cleaning PostgreSQL database...")

    # PostgreSQL connection details
    username = "bn_keycloak"
    password = "bn_keycloak"
    host = "localhost"
    port = "5442"
    database = "eudiwalletdb"

    try:
        # Connect to PostgreSQL
        conn = psycopg2.connect(
            dbname=database,
            user=username,
            password=password,
            host=host,
            port=port,
        )
        conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
        cursor = conn.cursor()

        # Get all tables in the public schema except alembic_version
        cursor.execute(
            """
            SELECT tablename FROM pg_tables 
            WHERE schemaname = 'public' 
            AND tablename != 'alembic_version'
        """
        )
        tables = cursor.fetchall()

        total_records_deleted = 0
        # Truncate each table
        for table in tables:
            table_name = table[0]

            # Get record count before truncate
            cursor.execute(f'SELECT COUNT(*) FROM "{table_name}"')
            record_count = cursor.fetchone()[0]

            # Truncate table
            cursor.execute(f'TRUNCATE TABLE "{table_name}" CASCADE')

            logger.info(
                f"🗑️ Truncated table: {table_name} (Deleted {record_count} records)"
            )
            total_records_deleted += record_count

        logger.info(
            f"✅ Successfully truncated all tables in PostgreSQL database. Total records deleted: {total_records_deleted}"
        )

    except Exception as e:
        logger.error(f"❌ Error truncating PostgreSQL tables: {str(e)}")

    finally:
        if cursor:
            cursor.close()
        if conn:
            conn.close()


def delete_keycloak():
    """Delete all realms except Master and igrant-users, and truncate users in igrant-users."""
    logger.info("🗑️ Cleaning Keycloak...")

    # Keycloak admin credentials and endpoint
    admin_username = "keycloak"
    admin_password = "j3ckN4914IOK"  # Replace with actual admin password
    keycloak_url = "http://localhost:8082"  # Adjust if your Keycloak is running on different host/port

    try:
        # Get admin access token
        token_url = (
            f"{keycloak_url}/auth/realms/master/protocol/openid-connect/token"
        )
        token_data = {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": admin_username,
            "password": admin_password,
        }
        token_response = requests.post(token_url, data=token_data)
        token_response.raise_for_status()
        access_token = token_response.json()["access_token"]

        # Set up headers for subsequent requests
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        }

        # Get list of all realms
        realms_url = f"{keycloak_url}/auth/admin/realms"
        realms_response = requests.get(realms_url, headers=headers)
        realms_response.raise_for_status()
        realms = realms_response.json()

        # Delete all realms except 'master' and 'igrant-users'
        protected_realms = ["master", "igrant-users"]
        for realm in realms:
            realm_name = realm["realm"]
            if realm_name not in protected_realms:
                delete_url = f"{keycloak_url}/auth/admin/realms/{realm_name}"
                delete_response = requests.delete(delete_url, headers=headers)
                delete_response.raise_for_status()
                logger.info(f"🗑️ Deleted realm: {realm_name}")

        # Delete all users from igrant-users realm except admin
        users_url = f"{keycloak_url}/auth/admin/realms/igrant-users/users"
        users_response = requests.get(users_url, headers=headers)
        users_response.raise_for_status()
        users = users_response.json()

        for user in users:
            if user["username"] != "admin":
                user_id = user["id"]
                delete_user_url = f"{keycloak_url}/auth/admin/realms/igrant-users/users/{user_id}"
                delete_user_response = requests.delete(
                    delete_user_url, headers=headers
                )
                delete_user_response.raise_for_status()
                logger.info(f"🗑️ Deleted user: {user['username']}")

        logger.info("✅ Successfully cleaned up Keycloak")

    except requests.exceptions.RequestException as e:
        logger.error(f"❌ Error cleaning up Keycloak via API: {str(e)}")


if __name__ == "__main__":
    logger.info("🔍 Checking for running processes...")
    processes = get_relevant_processes()
    if not processes:
        logger.info("🧹 Starting database cleanup...")
        delete_mongodb()
        delete_postgresql()
        delete_keycloak()
        logger.info("✨ Database cleanup completed successfully!")
    else:
        port_forward_processes = filter_port_forward_processes(processes)
        if port_forward_processes:
            logger.warning(
                "\n🚨 WARNING: The following port-forward processes with 'mongo' will be killed before database purge:\n"
            )
            for proc in port_forward_processes:
                logger.info(f"  📌 {proc}")
            confirm = (
                input("\n❓ Do you want to proceed? (yes/no): ").strip().lower()
            )
            if confirm == "yes":
                kill_processes(port_forward_processes)
                logger.info(
                    "✅ All relevant processes killed. Proceeding with database purge..."
                )
                delete_mongodb()
                delete_postgresql()
                delete_keycloak()
                logger.info("✨ Database cleanup completed successfully!")
            else:
                logger.info("❌ Aborted. No processes were killed.")
        else:
            logger.info(
                "✅ No relevant port-forward processes found. Proceeding normally."
            )
            delete_mongodb()
