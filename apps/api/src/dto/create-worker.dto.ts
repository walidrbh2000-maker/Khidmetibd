import {
  IsString, IsEmail, IsOptional, IsNumber, IsNotEmpty,
  IsBoolean, MinLength, MaxLength, Min, Max,
} from 'class-validator';

export class CreateWorkerDto {
  @IsString()
  @IsNotEmpty()
  id: string;

  @IsString()
  @IsNotEmpty()
  @MinLength(2)
  @MaxLength(50)
  name: string;

  @IsEmail()
  email: string;

  @IsString()
  @IsOptional()
  phoneNumber?: string;

  @IsString()
  @IsNotEmpty()
  profession: string;

  @IsBoolean()
  @IsOptional()
  isOnline?: boolean;

  @IsNumber()
  @IsOptional()
  @Min(-90)
  @Max(90)
  latitude?: number;

  @IsNumber()
  @IsOptional()
  @Min(-180)
  @Max(180)
  longitude?: number;

  @IsString()
  @IsOptional()
  profileImageUrl?: string;

  @IsString()
  @IsOptional()
  fcmToken?: string;
}
