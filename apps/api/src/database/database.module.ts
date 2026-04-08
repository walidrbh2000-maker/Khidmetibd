import { Module, Global } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { User, UserSchema } from '../schemas/user.schema';
import { Worker, WorkerSchema } from '../schemas/worker.schema';
import { ServiceRequest, ServiceRequestSchema } from '../schemas/service-request.schema';
import { WorkerBid, WorkerBidSchema } from '../schemas/worker-bid.schema';
import { Notification, NotificationSchema } from '../schemas/notification.schema';
import { GeographicCell, GeographicCellSchema } from '../schemas/geographic-cell.schema';

const MODELS = MongooseModule.forFeature([
  { name: User.name,             schema: UserSchema },
  { name: Worker.name,           schema: WorkerSchema },
  { name: ServiceRequest.name,   schema: ServiceRequestSchema },
  { name: WorkerBid.name,        schema: WorkerBidSchema },
  { name: Notification.name,     schema: NotificationSchema },
  { name: GeographicCell.name,   schema: GeographicCellSchema },
]);

@Global()
@Module({
  imports: [MODELS],
  exports: [MODELS],
})
export class DatabaseModule {}
