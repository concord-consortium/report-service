// adds methods created in response-methods middleware to express's Response type

// tslint:disable-next-line:no-namespace
declare namespace Express {
  export interface Response {
    error: (message: any, status?: number) => Response;
    success: (payload: string | object) => Response;
  }
}
