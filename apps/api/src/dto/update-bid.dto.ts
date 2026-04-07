import { IsEnum, IsOptional, IsDate } from 'class-validator';
import { Type } from 'class-transformer';
import { BidStatus } from '../common/enums';

export class UpdateBidDto {
  @IsEnum(BidStatus)
  @IsOptional()
  status?: BidStatus;

  @IsDate()
  @IsOptional()
  @Type(() => Date)
  acceptedAt?: Date;
}
