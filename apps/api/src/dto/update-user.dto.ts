import { PartialType } from '@nestjs/mapped-types';
import { CreateUserDto } from './create-user.dto';
import { IsString, IsOptional } from 'class-validator';

export class UpdateUserDto extends PartialType(CreateUserDto) {
  @IsString()
  @IsOptional()
  cellId?: string;

  @IsString()
  @IsOptional()
  geoHash?: string;

  @IsOptional()
  wilayaCode?: number;
}
