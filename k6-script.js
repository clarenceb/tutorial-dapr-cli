import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 10 },
  ],
};

export default function() {
  let payload = { data: { orderId: Math.random().toString(16).substr(2, 8).toString() }};

  console.log("Creating order: " + payload.data.orderId);

  let res = http.post(`${__ENV.URL}`, JSON.stringify(payload), {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, { 'status was 200': r => r.status == 200 });
  sleep(0.5)
}
