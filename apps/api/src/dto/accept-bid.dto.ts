import { IsNotEmpty, IsString } from 'class-validator';

export class AcceptBidDto {
  @IsString()
  @IsNotEmpty()
  requestId: string;
}
