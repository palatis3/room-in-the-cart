import {createOperationsHandler} from '../service/dist/operations-http.js';

// Separate function/pool/credentials; the public application runtime is not loaded.
const {handler}=createOperationsHandler();
export default handler;
