import http from 'k6/http';
import { check, sleep } from 'k6';

// Get the API endpoint URL from the environment
const API_ENDPOINT = __ENV.API_ENDPOINT;

// Test configuration
export const options = {
  stages: [
    { duration: '30s', target: 50 }, 
    { duration: '1m', target: 50 },  
    { duration: '10s', target: 0 },   
  ],
};

// The main test function
export default function () {
  const payload = JSON.stringify({
    event_type: 'button_click',
    url: '/checkout',
    user_id: `user-${Math.random()}`,
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
  };

  const res = http.post(API_ENDPOINT, payload, params);

  check(res, { 'status was 200': (r) => r.status == 200 });
  sleep(1); 
}