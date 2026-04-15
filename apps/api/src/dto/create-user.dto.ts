import {
  IsString, IsEmail, IsOptional, IsNumber, IsNotEmpty,
  IsEnum, Matches, MinLength, MaxLength, Min, Max,
} from 'class-validator';
import { UserRole } from '../schemas/user.schema';

export class CreateUserDto {
  @IsString()
  @IsNotEmpty()
  id: string;

  @IsString()
  @IsNotEmpty()
  @MinLength(2)
  @MaxLength(50)
  name: string;

  /**
   * Email optionnel — les utilisateurs Phone Auth peuvent ne pas en avoir.
   * Laisser vide ('') ou omettre pour un profil téléphone uniquement.
   */
  @IsEmail()
  @IsOptional()
  email?: string;

  /** Defaults to 'client'. Pass 'worker' when registering a worker account. */
  @IsEnum(UserRole)
  @IsOptional()
  role?: UserRole;

  /**
   * Numéro de téléphone algérien — format E.164 (+213XXXXXXXXX)
   * ou format local (0[5-7]XXXXXXXX).
   * Sera stocké en E.164 après normalisation côté service.
   */
  @IsString()
  @IsOptional()
  @Matches(/^(\+213[5-7]\d{8}|0[5-7]\d{8})$/, {
    message: 'phoneNumber must be a valid Algerian number (+213XXXXXXXXX or 0XXXXXXXXX)',
  })
  phoneNumber?: string;

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
