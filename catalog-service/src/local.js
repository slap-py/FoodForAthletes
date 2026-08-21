import { server } from "./server.js";

const port = Number(process.env.PORT ?? 8787);
server.listen(port, () => console.log(`Dayplate meal service listening on ${port}`));
