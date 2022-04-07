import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 10 },
  ],
};

export default function() {
  let payload = { data: { orderId: Math.random().toString(16).substr(2, 8).toString() }};
  let subscriptionKey = __ENV.SUBSCRIPTION_KEY || '';
  let url = __ENV.URL;
  let headers = { 'Content-Type': 'application/json' };

  if (!subscriptionKey && subscriptionKey.length > 0) {
    console.log("Subscription Key detected...")
    headers = { 'Content-Type': 'application/json', 'Ocp-Apim-Subscription-Key': subscriptionKey };
  }

  let res = http.post(`${__ENV.URL}`, JSON.stringify(payload), {
    headers: headers,
  });

  check(res, { 'status was 200': r => r.status == 200 });

  console.log(`Created order: ${payload.data.orderId} => ${res.status}: ${res.status_text}`);

  sleep(0.5);
}
