import { HttpException, HttpStatus } from '@nestjs/common';

export class AiProviderException extends HttpException {
  constructor(
    message: string,
    status: HttpStatus = HttpStatus.SERVICE_UNAVAILABLE,
  ) {
    super({ success: false, message }, status);
  }
}

export class AiRateLimitException extends HttpException {
  constructor() {
    super(
      { success: false, message: 'AI rate limit exceeded. Max 20 requests per hour.' },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }
}
