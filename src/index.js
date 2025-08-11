const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { Client } = require("pg");
const crypto = require("crypto");

const s3Client = new S3Client({ region: "us-east-1" });
const ddbClient = new DynamoDBClient({ region: "us-east-1" });
const ddbDocClient = DynamoDBDocumentClient.from(ddbClient);
const secretsManagerClient = new SecretsManagerClient({ region: "us-east-1" });

const { S3_BUCKET_NAME, DDB_TABLE_NAME, RDS_SECRET_ARN, RDS_DB_HOSTNAME, RDS_DB_NAME } = process.env;

let dbClient;

async function initializeDbClient() {
    if (dbClient && dbClient._connected) {
        return;
    }

    console.log("Attempting to initialize database connection...");
    
    const secretValue = await secretsManagerClient.send(
        new GetSecretValueCommand({ SecretId: RDS_SECRET_ARN })
    );
    const credentials = JSON.parse(secretValue.SecretString);

    dbClient = new Client({
        host: RDS_DB_HOSTNAME,
        port: 5432,
        user: credentials.username,
        password: credentials.password,
        database: RDS_DB_NAME,
        connectionTimeoutMillis: 5000, 
        ssl: {
          rejectUnauthorized: false
        }
    });

    await dbClient.connect();
    console.log("Database connected successfully.");

    await dbClient.query(`
        CREATE TABLE IF NOT EXISTS event_counts (
            event_type VARCHAR(255) PRIMARY KEY,
            count BIGINT NOT NULL
        );
    `);
    console.log("Table 'event_counts' is ready.");
}

exports.handler = async (event) => {
    try {
        await initializeDbClient();

        let parsedBody;
        try {
            parsedBody = JSON.parse(event.body);
        } catch (e) {
            return { statusCode: 400, body: JSON.stringify({ message: "Invalid JSON format." }) };
        }

        const eventId = crypto.randomUUID();
        const receivedAt = new Date().toISOString();

        await Promise.all([
            s3Client.send(new PutObjectCommand({ Bucket: S3_BUCKET_NAME, Key: `events/${receivedAt}-${eventId}.json`, Body: event.body, ContentType: "application/json" })),
            ddbDocClient.send(new PutCommand({ TableName: DDB_TABLE_NAME, Item: { eventId, receivedAt, eventType: parsedBody.event_type, url: parsedBody.url } })),
            dbClient.query(`INSERT INTO event_counts (event_type, count) VALUES ($1, 1) ON CONFLICT (event_type) DO UPDATE SET count = event_counts.count + 1;`, [parsedBody.event_type])
        ]);

        console.log("All operations completed successfully.");
        return { statusCode: 200, body: JSON.stringify({ message: "Event processed and stored successfully!", eventId }) };

    } catch (error) {
        console.error("HANDLER CAUGHT ERROR:", error); 
        return {
            statusCode: 500,
            body: JSON.stringify({ message: "An internal error occurred.", errorName: error.name, errorMessage: error.message }),
        };
    }
};