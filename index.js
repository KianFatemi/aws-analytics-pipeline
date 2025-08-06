const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");
const crypto = require("crypto");

const s3Client = new S3Client({ region: "us-east-1" });
const ddbClient = new DynamoDBClient({ region: "us-east-1" });
const ddbDocClient = DynamoDBDocumentClient.from(ddbClient);

const S3_BUCKET_NAME = process.env.S3_BUCKET_NAME;
const DDB_TABLE_NAME = process.env.DDB_TABLE_NAME;

exports.handler = async (event) => {
  console.log("Received event:", JSON.stringify(event, null, 2));

  let parsedBody;
  try {
    parsedBody = JSON.parse(event.body);
  } catch (e) {
    console.error("Could not parse request body:", e);
    return {
      statusCode: 400,
      body: JSON.stringify({ message: "Invalid JSON format." }),
    };
  }
  
  const eventId = crypto.randomUUID();
  const receivedAt = new Date().toISOString();

  try {
    const s3Params = {
      Bucket: S3_BUCKET_NAME,
      Key: `events/${receivedAt}-${eventId}.json`, 
      Body: event.body,
      ContentType: "application/json",
    };
    await s3Client.send(new PutObjectCommand(s3Params));
    console.log("Successfully saved raw event to S3");
  } catch (err) {
    console.error("S3 Error:", err);
  }

  try {
    const ddbParams = {
      TableName: DDB_TABLE_NAME,
      Item: {
        eventId: eventId,
        receivedAt: receivedAt,
        eventType: parsedBody.event_type,
        url: parsedBody.url,
      },
    };
    await ddbDocClient.send(new PutCommand(ddbParams));
    console.log("Successfully saved processed event to DynamoDB");
  } catch (err) {
    console.error("DynamoDB Error:", err);
  }

  const response = {
    statusCode: 200,
    body: JSON.stringify({ message: "Event processed and stored successfully!", eventId: eventId }),
  };

  return response;
};